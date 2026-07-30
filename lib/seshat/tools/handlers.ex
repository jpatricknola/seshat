defmodule Seshat.Tools.Handlers do
  @moduledoc """
  Dispatches tool calls to their implementations.

  Shared by both MCP and API key modes. Takes a tool name and input map and
  returns a result suitable for sending back to the LLM. Single-message tools
  talk to `Seshat.OSC.Transport` directly; multi-step sequences (create_track,
  create_return_track, write_midi_notes) build a `%Command{}` and execute it via
  `Seshat.Commands.Registry`.
  """

  require Logger

  alias Seshat.Commands.{Command, Registry}
  alias Seshat.Library.Catalog
  alias Seshat.Music.Pitch
  alias Seshat.OSC.Transport
  alias Seshat.Session.State
  alias Seshat.Tools.FollowCam

  # Browsing and loading are both far slower than a property read: the first
  # walk of a big browser category takes seconds, and a heavy plugin can take
  # tens of seconds to instantiate.
  @browse_timeout 15_000
  @load_timeout 30_000

  # Guards that run before a mutation read a single track/slot property, which
  # is sub-millisecond over loopback. A bad index never replies at all
  # (AbletonOSC raises IndexError inside the callback and nothing is sent), so
  # the timeout is really "how long until we call it a bad index" — the house
  # 5s default would turn a typo into a five-second stall on the happy path's
  # own error branch.
  @guard_timeout 2_000

  @default_max_results 25
  @default_catalog_results 15

  # Marks search steering text as model-internal, at the point of use. The
  # 2026-07-28 validation run had "No 'Warm' tag exists in your library" relayed
  # verbatim to a musician who never asked about tags: the diagnose/facet text
  # did its real job (steering the model's retry) but was never meant to be
  # quoted. It travels with the text it governs rather than sitting in the tool
  # description, so it reaches the model exactly when it matters, in both modes.
  # Wording matches the session instructions' "speak music, not plumbing" rule.
  @diagnostics_internal "(Diagnostics are for refining your search — present results musically; " <>
                          "don't mention tags to the user.)"

  # Advice appended to a guard timeout, per address family. A timeout means "no
  # reply at all", which for an upstream address is nearly always a bad index and
  # for one of Seshat's own is that plus "the extension was never installed".
  @clip_index_hint "An index that doesn't exist gets no reply from Ableton at all, so check the " <>
                     "track and slot indices with get_clip_slots first; failing that, check " <>
                     "Ableton is running with AbletonOSC enabled."

  @send_index_hint "An index that doesn't exist gets no reply from Ableton at all, so check the " <>
                     "track index (get_session_state) and send index (get_track_sends; sends are " <>
                     "0-based, send A = 0)."

  @track_index_hint "An index that doesn't exist gets no reply from Ableton at all, so check the " <>
                      "track index with get_session_state; failing that, check Ableton is " <>
                      "running with AbletonOSC enabled."

  @device_index_hint "An index that doesn't exist gets no reply from Ableton at all, so check " <>
                       "the track and device indices with get_track_devices first; failing " <>
                       "that, check Ableton is running with AbletonOSC enabled."

  # The return/master addresses are Seshat's own, and they always reply — a bad
  # index comes back as an error envelope, not silence. So unlike the upstream
  # families above, a timeout here isn't a bad index at all: it means nothing is
  # serving the address.
  @return_extension_hint "These addresses come from Seshat's AbletonOSC extension rather than " <>
                           "upstream, and it answers every query it receives — even for an index " <>
                           "that doesn't exist. Silence therefore means it isn't installed: run " <>
                           "`mix abletonosc.install` and restart Ableton Live, and check Live is " <>
                           "running with AbletonOSC enabled."

  # --- Clip properties (get_clip_properties / set_clip_properties) ---
  #
  # Property names are the OSC address suffixes, so one list drives the schema,
  # the reads, the writes and the echo. The addresses themselves stay as
  # literals in `clip_get_address/1` / `clip_set_address/1` rather than being
  # interpolated from these names — the `"/live/` greppability rule.

  # Written to Live as 1/0.
  @clip_boolean_properties ["looping", "legato", "warping"]

  # Enums — written as integers, decoded to names in the replies.
  @clip_integer_properties ["launch_mode", "launch_quantization", "warp_mode"]

  # The two ordered pairs. Live requires start < end at all times, so each pair
  # is written in whichever order keeps that true after every single message
  # (see `clip_property_writes/2`).
  @clip_pair_properties [{"loop_start", "loop_end"}, {"start_marker", "end_marker"}]

  # Anything that changes the clip's audible extent — writing one of these makes
  # `length` worth reading back.
  @clip_range_properties ["looping", "loop_start", "loop_end", "start_marker", "end_marker"]

  # Unpaired properties, written last in this order. Order is fixed rather than
  # map-iteration order so the write list is deterministic and testable.
  @clip_scalar_properties [
    "launch_mode",
    "launch_quantization",
    "legato",
    "velocity_amount",
    "gain",
    "warp_mode",
    "warping"
  ]

  # `Clip` only carries these on an audio clip; reading or writing one on a MIDI
  # clip raises inside AbletonOSC's callback, which sends nothing back — a guard
  # timeout burned on an answer we already know.
  @clip_audio_only_properties ["gain", "warp_mode", "warping"]

  @clip_writable_properties @clip_range_properties ++ @clip_scalar_properties

  @clip_common_reads [
    "name",
    "length",
    "looping",
    "loop_start",
    "loop_end",
    "start_marker",
    "end_marker",
    "launch_mode",
    "launch_quantization",
    "legato",
    "velocity_amount"
  ]

  @clip_audio_reads ["gain", "gain_display_string", "warp_mode", "warping"]

  @launch_mode_names %{0 => "Trigger", 1 => "Gate", 2 => "Toggle", 3 => "Repeat"}

  @launch_quantization_names %{
    0 => "Global",
    1 => "None",
    2 => "8 bars",
    3 => "4 bars",
    4 => "2 bars",
    5 => "1 bar",
    6 => "1/2",
    7 => "1/2T",
    8 => "1/4",
    9 => "1/4T",
    10 => "1/8",
    11 => "1/8T",
    12 => "1/16",
    13 => "1/16T",
    14 => "1/32"
  }

  @warp_mode_names %{
    0 => "Beats",
    1 => "Tones",
    2 => "Texture",
    3 => "Re-Pitch",
    4 => "Complex",
    6 => "Complex Pro"
  }

  # Properties for the /live/song/get/track_data bulk query, in reply order.
  # Each track.* property contributes one value per track; each clip.* /
  # clip_slot.* property contributes num_scenes values — so a track's chunk is
  # 3 + 5 * num_scenes values. parse_track_data/3 depends on this exact order.
  @track_data_properties [
    "track.name",
    "track.has_midi_input",
    "track.is_foldable",
    "clip_slot.has_clip",
    "clip.name",
    "clip.length",
    "clip.is_playing",
    "clip.is_recording"
  ]

  # Batch size for track_data queries: keeps any single reply datagram far
  # below the Transport's 64KB socket buffer (a truncated datagram surfaces as
  # a mystery timeout). One batch covers any normal set.
  @track_data_target_values 4000

  # How long `capture_midi` waits before its single re-read, for the case where
  # Live defers inserting the captured clip past the LOM call's return. Short
  # enough to be invisible next to the round trips either side of it.
  @capture_retry_delay 250

  # A delete steers to whatever now occupies the index it emptied, which needs
  # the post-delete count. Best-effort by design: this read exists only to aim
  # the view, so it gets the guard timeout rather than the 5s default and a
  # miss simply skips the steering — never the tool's own success reply.
  @follow_cam_count_timeout 2_000

  @spec call(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def call(name, params) when is_binary(name) and is_map(params) do
    do_call(name, stringify_keys(params))
  end

  @doc """
  Recursively converts map keys to strings.

  Params arrive string-keyed from the Anthropic API but atom-keyed from MCP,
  where Peri validates against an atom-keyed schema. Normalising here means the
  clauses below only ever deal with one shape — an atom-keyed map otherwise
  falls straight through to the "Unknown tool" clause.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  @doc """
  Formats the flat `[name, path, uri, name, path, uri, ...]` tail of a
  `/live/browser/get/items` reply into one line per item.

  `total` is how many items matched before truncation, so the model can tell
  "that's all of them" from "there are more, narrow the filter".
  """
  @spec format_browser_items(list(), non_neg_integer()) :: String.t()
  def format_browser_items([], _total) do
    "No matching browser items. Try a shorter filter, a different spelling, or another category."
  end

  def format_browser_items(triples, total) do
    items = Enum.chunk_every(triples, 3, 3, :discard)

    listing =
      Enum.map_join(items, "\n", fn [name, path, uri] ->
        "#{name}#{format_path(path)} — uri: #{uri}"
      end)

    header =
      if length(items) < total do
        "Showing #{length(items)} of #{total} matches — refine the filter to see the rest."
      else
        "#{length(items)} match(es):"
      end

    "#{header}\n\n#{listing}"
  end

  @doc """
  Formats catalog entries as `name — tags [paths] (uri)`, one per line.

  The tags are the whole reason to prefer this over a raw browser listing, so
  they lead; the uri trails because it is for the next tool call, not the user.

  One entry is one preset, so a preset Live files in several places lists all
  of them — "Analog/Synth Lead · Operator/Synth Lead" says which devices can
  play it, which is real information for choosing. It is still shorter than the
  repeated rows it replaces.

  The third argument is what makes a partial answer actionable rather than a dead
  end: `Catalog.diagnose/1`'s map when nothing matched, so the reply can name the
  tag that killed the search and the real ones near it, and otherwise
  `Catalog.search/1`'s facets, so a truncated reply offers the tags that would
  narrow it. Both carry this library's own vocabulary, which no fixed list can.
  """
  @spec format_catalog_entries([map()], non_neg_integer(), [{String.t(), pos_integer()}] | map()) ::
          String.t()
  def format_catalog_entries([], _total, diagnosis) do
    "No catalog matches.#{format_diagnosis(diagnosis)} If the catalog has never been built, " <>
      "run reindex_library."
  end

  def format_catalog_entries(entries, total, facets) do
    listing =
      Enum.map_join(entries, "\n", fn entry ->
        "#{entry.name} — #{format_tags(entry.tags)}#{format_paths(entry.paths)} (#{entry.uri})"
      end)

    header =
      cond do
        length(entries) >= total ->
          "#{length(entries)} match(es):"

        facets == [] ->
          "Showing #{length(entries)} of #{total} matches — narrow the query or add a tag to " <>
            "see the most relevant ones."

        true ->
          "Showing #{length(entries)} of #{total} matches — top tags among them: " <>
            "#{format_tag_counts(facets)}. Add one as a tag to narrow. " <>
            @diagnostics_internal
      end

    "#{header}\n\n#{listing}"
  end

  # Nothing matched and nothing to say about why — an empty catalog, which the
  # search_library clause reports before it ever gets here.
  defp format_diagnosis(diagnosis) when not is_map(diagnosis), do: ""

  defp format_diagnosis(diagnosis) do
    notes =
      Enum.map(diagnosis.tags, &tag_note/1) ++
        [
          constraint_note("Query", diagnosis.query, diagnosis.query_matches),
          constraint_note("Category", diagnosis.category, diagnosis.category_matches)
        ]

    case Enum.reject(notes, &(&1 == "")) do
      [] ->
        ""

      notes ->
        " " <>
          Enum.join(notes, " ") <> " " <> retry_advice(diagnosis) <> " " <> @diagnostics_internal
    end
  end

  defp tag_note(%{tag: tag, matches: 0, nearest: []}) do
    "Tag '#{tag}' matches nothing in this library."
  end

  defp tag_note(%{tag: tag, matches: 0, nearest: nearest}) do
    "Tag '#{tag}' matches nothing in this library — nearest real tags: " <>
      "#{format_tag_counts(nearest)}."
  end

  defp tag_note(%{tag: tag, matches: matches}), do: "'#{tag}' alone matches #{matches}."

  # nil means the constraint was never set, which is not worth a sentence.
  defp constraint_note(_label, _value, nil), do: ""

  defp constraint_note(label, value, 0), do: "#{label} '#{value}' alone matches nothing."
  defp constraint_note(label, value, matches), do: "#{label} '#{value}' alone matches #{matches}."

  # Two independent things the model needs: *why* it got nothing, and *what to
  # send next*. Folding them into one branch loses whichever it didn't pick —
  # a combination failure with narrowing tags available needs both sentences.
  defp retry_advice(diagnosis) do
    [cause_note(diagnosis), narrowing_note(diagnosis)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  # A tag that matched nothing has already been named, with its count, above.
  defp cause_note(diagnosis) do
    if Enum.any?(diagnosis.tags, &(&1.matches == 0)) do
      ""
    else
      "Every constraint matches something on its own, so it is the combination that fails."
    end
  end

  # Naming tags that would actually work is the difference between a dead end and
  # a one-step retry — and string similarity can't supply them when the model
  # guessed a word this library has no spelling of ("Warm", against a vocabulary
  # whose nearest neighbour is "Marimba"). The tags on what the query alone
  # reaches can.
  defp narrowing_note(%{narrowing_tags: [_ | _] = narrowing}) do
    "Real tags on those: #{format_tag_counts(narrowing)} — retry with one of them rather " <>
      "than abandoning the search."
  end

  defp narrowing_note(_diagnosis) do
    "Drop the query down to just the kind of sound, or search with fewer tags."
  end

  defp format_tag_counts(counts) do
    Enum.map_join(counts, ", ", fn {tag, count} -> "#{tag} (#{count})" end)
  end

  @doc """
  Formats a `Catalog.reindex/1` summary.

  A reindex is when the tag vocabulary changes, so it is when the model should be
  told what it now is — the tool description can't, since the vocabulary depends
  on which Packs this user has installed. The distinct count says how much of it
  the sample leaves out.
  """
  @spec format_reindex_summary(map()) :: String.t()
  def format_reindex_summary(%{items: items, tagged: tagged} = summary) do
    "Reindexed the sound catalog: #{items} item(s), #{tagged} of them tagged by Ableton. " <>
      "#{format_vocabulary(summary)}search_library is ready."
  end

  defp format_vocabulary(%{distinct_tags: 0}), do: ""

  defp format_vocabulary(%{distinct_tags: distinct, top_tags: top}) do
    ending = if distinct > length(top), do: ", …", else: "."

    "#{distinct} distinct tags — most common: #{format_tag_counts(top)}#{ending} "
  end

  defp format_tags([]), do: "no tags"
  defp format_tags(tags), do: Enum.join(tags, ", ")

  # One location, for a raw browser listing.
  defp format_path(path) when path in [nil, ""], do: ""
  defp format_path(path), do: " [#{path}]"

  # Every location a catalog entry has, since one entry is one preset.
  defp format_paths(paths) do
    case Enum.reject(List.wrap(paths), &(&1 in [nil, ""])) do
      [] -> ""
      list -> " [#{Enum.join(list, " · ")}]"
    end
  end

  @doc """
  Formats the parallel name/type/class_name lists of the
  `/live/track/get/devices/*` replies into one line per device, in chain order.
  """
  @spec format_device_chain(integer(), list(), list(), list()) :: String.t()
  def format_device_chain(track, [], _types, _classes) do
    "No devices on track #{track}. If this is a MIDI track it will be silent — " <>
      "load an instrument with list_browser_items + load_device."
  end

  def format_device_chain(track, names, types, classes) do
    lines =
      [names, types, classes]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{name, type, class}, index} ->
        "Device #{index} \"#{name}\" — #{device_type_label(type)} (#{class})"
      end)

    "#{length(names)} device(s) on track #{track}:\n\n#{lines}"
  end

  @doc """
  The out-of-range error for `delete_device`, raised in Elixir before anything
  reaches the wire.

  `/live/track/delete_device` never replies, and a bad device index only raises
  inside AbletonOSC's callback — so an unchecked index costs a full verification
  timeout and still can't say what went wrong. Checking against the chain we
  just read says it immediately, and prints the chain so the retry is one step.
  """
  @spec device_out_of_range_error(integer(), integer(), list()) :: String.t()
  def device_out_of_range_error(track, device, []) do
    "Track #{track} has no devices, so there is nothing to delete (asked for device " <>
      "#{device}). Check the chain with get_track_devices."
  end

  def device_out_of_range_error(track, device, names) do
    "Track #{track} has #{length(names)} device(s) (indices 0–#{length(names) - 1}) — there " <>
      "is no device #{device}. Chain: #{format_chain_inline(names)}."
  end

  @doc """
  The success reply for `delete_device`, listing the chain that is left.

  Every device after the deleted one has just moved down an index, so any index
  the model noted earlier is now wrong. Re-listing the chain from the names read
  before the delete costs nothing and saves a `get_track_devices` round trip
  that the model would otherwise have to know to make.
  """
  @spec deleted_device_reply(integer(), integer(), list()) :: String.t()
  def deleted_device_reply(track, device, names) do
    deleted = Enum.at(names, device)

    case List.delete_at(names, device) do
      [] ->
        "Deleted '#{deleted}' (device #{device}) from track #{track}. Its device chain is now " <>
          "empty."

      remaining ->
        "Deleted '#{deleted}' (device #{device}) from track #{track}. Remaining chain: " <>
          "#{format_chain_inline(remaining)} — later device indices have shifted down by one."
    end
  end

  defp format_chain_inline(names) do
    names
    |> Enum.with_index()
    |> Enum.map_join(", ", fn {name, index} -> "#{index}: #{name}" end)
  end

  @doc """
  Refuses the bypass unless parameter 0's display value reads On/Off.

  Turns "parameter 0 is the Device On switch" from a load-bearing assumption
  into a refusal that prints what it actually found — the whole tool hangs on
  this guard until the assumption is smoke-tested against a live Ableton.
  """
  @spec ensure_on_off_switch(String.t(), term()) :: :ok | {:error, String.t()}
  def ensure_on_off_switch(name, display) do
    if String.downcase(to_string(display)) in ["on", "off"] do
      :ok
    else
      {:error,
       "Parameter 0 of '#{name}' reads '#{display}', not On/Off — this device doesn't expose " <>
         "the standard Device On switch at parameter 0, so nothing was changed. Inspect it " <>
         "with get_device_parameters instead."}
    end
  end

  @doc """
  The success reply for `bypass_device`, once the toggle is confirmed.
  """
  @spec bypass_reply(String.t(), integer(), integer(), boolean()) :: String.t()
  def bypass_reply(name, track, device, true) do
    "'#{name}' (device #{device} on track #{track}) is now On."
  end

  def bypass_reply(name, track, device, false) do
    "'#{name}' (device #{device} on track #{track}) is now Off — bypassed, settings kept."
  end

  @doc """
  The no-op reply for `bypass_device` — parameter 0 already read the requested
  state, so nothing was written and the reply must not claim otherwise.
  """
  @spec bypass_noop_reply(String.t(), integer(), integer(), boolean()) :: String.t()
  def bypass_noop_reply(name, track, device, enabled) do
    "'#{name}' (device #{device} on track #{track}) was already #{on_off_label(enabled)} — " <>
      "nothing to do."
  end

  defp on_off_label(true), do: "On"
  defp on_off_label(false), do: "Off"

  @doc """
  Formats the parallel parameter name/value/min/max lists of the
  `/live/device/get/parameters/*` replies into one line per parameter.
  """
  @spec format_device_parameters(integer(), integer(), String.t(), list(), list(), list(), list()) ::
          String.t()
  def format_device_parameters(track, device, device_name, names, values, mins, maxes) do
    lines =
      [names, values, mins, maxes]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{name, value, min, max}, index} ->
        "#{index}. #{name} = #{format_number(value)} (range #{format_number(min)}–#{format_number(max)})"
      end)

    "Device #{device} \"#{device_name}\" on track #{track} — #{length(names)} parameter(s):\n\n#{lines}"
  end

  @doc """
  Chunks the flat tail of a `/live/clip/get/notes` reply into one map per note.

  AbletonOSC contributes exactly five fields per note — pitch, start_time,
  duration, velocity, mute — so a tail that isn't a multiple of five means the
  reply shape changed upstream. Fail loudly there rather than silently dropping
  a partial note and reporting a clip that isn't what Live holds.
  """
  @spec parse_clip_notes(list()) :: {:ok, [map()]} | {:error, String.t()}
  def parse_clip_notes(fields) when is_list(fields) do
    if rem(length(fields), 5) == 0 do
      notes =
        fields
        |> Enum.chunk_every(5)
        |> Enum.map(fn [pitch, start_time, duration, velocity, mute] ->
          %{
            pitch: pitch,
            start_time: start_time,
            duration: duration,
            velocity: velocity,
            mute: truthy?(mute)
          }
        end)

      {:ok, notes}
    else
      {:error,
       "Unexpected note data from Live: #{length(fields)} value(s) is not a whole number of " <>
         "notes (5 fields each). AbletonOSC may have changed its reply format — the clip was " <>
         "not read."}
    end
  end

  @doc """
  Formats the notes of a clip, one per line, with note names beside the raw
  MIDI pitches.

  Sorted by start time, then pitch, so chords read as blocks and the model sees
  the clip in playing order rather than Live's internal order.
  """
  @spec format_clip_notes(integer(), integer(), String.t(), number(), [map()]) :: String.t()
  def format_clip_notes(track, slot, clip_name, clip_length, []) do
    ~s{Clip "#{clip_name}" on track #{track}, slot #{slot} — } <>
      "#{format_number(clip_length)} beats, no notes (the clip exists but is empty)."
  end

  def format_clip_notes(track, slot, clip_name, clip_length, notes) do
    lines =
      notes
      |> Enum.sort_by(&{&1.start_time, &1.pitch})
      |> Enum.map_join("\n", fn note ->
        muted = if note.mute, do: "  [muted]", else: ""

        "  " <>
          String.pad_trailing("#{Pitch.note_name(note.pitch)} (#{note.pitch})", 11) <>
          String.pad_trailing("start=#{format_number(note.start_time)}", 14) <>
          String.pad_trailing("dur=#{format_number(note.duration)}", 12) <>
          "vel=#{format_number(note.velocity)}#{muted}"
      end)

    header =
      ~s{Clip "#{clip_name}" on track #{track}, slot #{slot} — } <>
        "#{format_number(clip_length)} beats, #{length(notes)} note(s):"

    "#{header}\n\n#{lines}"
  end

  @doc """
  Chunks the flat `/live/song/get/track_data` reply into one map per track.

  The reply carries, per track, the values of `@track_data_properties` in
  order: 3 single track-level values, then 5 runs of `num_scenes` slot-level
  values. Empty slots contribute OSC nil for every `clip.*` property; a slot
  is empty iff `clip_slot.has_clip` is falsy, and the nils are discarded.

  A reply that isn't exactly `num_tracks * (3 + 5 * num_scenes)` values means
  the shape changed upstream — fail loudly rather than misattribute values to
  the wrong tracks (same guard as `parse_clip_notes/1`).
  """
  @spec parse_track_data(list(), pos_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, String.t()}
  def parse_track_data(values, num_scenes, num_tracks)
      when is_list(values) and num_scenes >= 1 and num_tracks >= 1 do
    per_track = 3 + 5 * num_scenes
    expected = num_tracks * per_track

    if length(values) == expected do
      tracks =
        values
        |> Enum.chunk_every(per_track)
        |> Enum.map(fn [name, has_midi_input, is_foldable | slot_values] ->
          [has_clips, clip_names, clip_lengths, playings, recordings] =
            Enum.chunk_every(slot_values, num_scenes)

          slots =
            [has_clips, clip_names, clip_lengths, playings, recordings]
            |> Enum.zip()
            |> Enum.map(fn {has_clip, clip_name, clip_length, playing, recording} ->
              if truthy?(has_clip) do
                %{
                  name: clip_name,
                  length: clip_length,
                  playing?: truthy?(playing),
                  recording?: truthy?(recording)
                }
              end
            end)

          %{
            name: name,
            midi?: truthy?(has_midi_input),
            group?: truthy?(is_foldable),
            slots: slots
          }
        end)

      {:ok, tracks}
    else
      {:error,
       "Unexpected clip-grid data from Live: got #{length(values)} value(s) for " <>
         "#{num_tracks} track(s) × #{num_scenes} scene(s), expected #{expected}. " <>
         "AbletonOSC may have changed its track_data reply format — the grid was not read."}
    end
  end

  @doc """
  Formats the parsed clip grid: the scene list, then one block per track.

  Occupied slots get a line each; consecutive empty slots collapse into ranges
  (with 30 scenes the output would otherwise be mostly the word "empty").
  Track label from the flags: `is_foldable` → group, else `has_midi_input` →
  MIDI, else audio. A recording clip shows only `[recording]` — Live reports
  it as playing too, and two flags would just be noise.
  """
  @spec format_clip_slots([String.t()], [map()]) :: String.t()
  def format_clip_slots(scenes, tracks) do
    scene_line =
      "#{length(scenes)} scene(s): " <>
        (scenes
         |> Enum.with_index()
         |> Enum.map_join(", ", fn {name, index} -> ~s(#{index} "#{name}") end))

    track_blocks =
      tracks
      |> Enum.with_index()
      |> Enum.map_join("\n", &format_track_slots/1)

    "#{scene_line}\n\n#{track_blocks}"
  end

  defp format_track_slots({track, index}) do
    label =
      cond do
        track.group? -> "group"
        track.midi? -> "MIDI"
        true -> "audio"
      end

    header = ~s{Track #{index} "#{track.name}" (#{label}):}

    empty_indices =
      for {slot, slot_index} <- Enum.with_index(track.slots), is_nil(slot), do: slot_index

    cond do
      length(empty_indices) == length(track.slots) ->
        "#{header} all #{length(track.slots)} slot(s) empty"

      empty_indices == [] ->
        "#{header}\n#{occupied_slot_lines(track.slots)}"

      true ->
        "#{header}\n#{occupied_slot_lines(track.slots)}\n" <>
          "  #{slot_label(empty_indices)}: empty"
    end
  end

  defp occupied_slot_lines(slots) do
    for {slot, index} <- Enum.with_index(slots), not is_nil(slot) do
      clip_name = if slot.name in [nil, ""], do: "(unnamed)", else: ~s("#{slot.name}")

      flag =
        cond do
          slot.recording? -> " [recording]"
          slot.playing? -> " [playing]"
          true -> ""
        end

      "  slot #{index}: #{clip_name} — #{format_number(slot.length)} beats#{flag}"
    end
    |> Enum.join("\n")
  end

  # [0, 1, 3] -> ~s(slots 0-1, 3); [3] -> ~s(slot 3)
  defp slot_label([index]), do: "slot #{index}"

  defp slot_label(indices) do
    ranges =
      indices
      |> Enum.reduce([], fn index, acc ->
        case acc do
          [{first, last} | rest] when index == last + 1 -> [{first, index} | rest]
          _ -> [{index, index} | acc]
        end
      end)
      |> Enum.reverse()
      |> Enum.map_join(", ", fn
        {first, first} -> "#{first}"
        {first, last} -> "#{first}-#{last}"
      end)

    "slots #{ranges}"
  end

  @doc """
  Diffs two `snapshot_grid/0` results: what `capture_midi` made appear.

  Returns `{new_clips, scenes_added}` — one map per slot that is occupied in
  `after_grid` and empty in `before_grid`, in track then slot order, plus how
  many scenes the grid grew by (capture adds one when it needs somewhere to put
  the clip).

  Tracks are matched by index, which is safe because capture never creates or
  reorders tracks. A slot beyond `before_grid`'s scene count — or on a track
  `before_grid` didn't have — counts as newly occupied: there was nothing there
  to be occupied before.
  """
  @spec capture_diff(map(), map()) :: {[map()], non_neg_integer()}
  def capture_diff(before_grid, after_grid) do
    new_clips =
      after_grid.tracks
      |> Enum.with_index()
      |> Enum.flat_map(fn {track, track_index} ->
        new_clips_on_track(before_grid, track, track_index)
      end)

    {new_clips, max(after_grid.num_scenes - before_grid.num_scenes, 0)}
  end

  defp new_clips_on_track(before_grid, track, track_index) do
    before_slots =
      case Enum.at(before_grid.tracks, track_index) do
        nil -> []
        before_track -> before_track.slots
      end

    for {slot, slot_index} <- Enum.with_index(track.slots),
        not is_nil(slot),
        is_nil(Enum.at(before_slots, slot_index)) do
      %{
        track_index: track_index,
        track_name: track.name,
        slot_index: slot_index,
        clip: slot
      }
    end
  end

  @doc """
  The success reply for `capture_midi`: what appeared, and what Live changed.

  Every fact here comes from the after-snapshot rather than from assumption —
  including whether Live started the clip playing, which depends on the
  transport state at capture time. The tempo line only appears when the two
  readings actually differ, which is Live's tempo inference showing up (it
  happens when the transport was stopped and Live guessed a tempo from the
  playing).
  """
  @spec captured_reply([map()], non_neg_integer(), number(), number()) :: String.t()
  def captured_reply(new_clips, scenes_added, tempo_before, tempo_after) do
    header = "Captured #{length(new_clips)} new clip(s):"
    lines = Enum.map_join(new_clips, "\n", &captured_clip_line/1)

    extras =
      [scene_added_line(scenes_added), tempo_change_line(tempo_before, tempo_after)]
      |> Enum.reject(&is_nil/1)

    Enum.join([header <> "\n" <> lines | extras], "\n\n")
  end

  defp captured_clip_line(%{track_index: track, track_name: name, slot_index: slot, clip: clip}) do
    clip_name = if clip.name in [nil, ""], do: "(unnamed)", else: ~s("#{clip.name}")
    playing = if clip.playing?, do: " [playing]", else: ""

    ~s{Track #{track} "#{name}", slot #{slot}: #{clip_name} — } <>
      "#{format_number(clip.length)} beats#{playing}"
  end

  defp scene_added_line(0), do: nil

  defp scene_added_line(count) do
    "Live added #{count} scene(s) to hold it."
  end

  defp tempo_change_line(tempo_before, tempo_after) when tempo_before == tempo_after, do: nil

  defp tempo_change_line(tempo_before, tempo_after) do
    "Live set the tempo to #{format_tempo(tempo_after)} BPM to match the playing " <>
      "(was #{format_tempo(tempo_before)})."
  end

  defp format_tempo(tempo), do: Float.round(tempo / 1, 1)

  @doc """
  The reply for a `capture_midi` that produced no new Session clip.

  An error rather than a soft success: the user asked to keep what they played
  and nothing was kept, so the model needs to say so and can act on the causes.
  A tempo change with *no* new clip is positive evidence that the capture landed
  somewhere the Session grid can't see, which upgrades the Arrangement caveat
  from a guess to the likely cause.
  """
  @spec nothing_captured_reply(number(), number()) :: String.t()
  def nothing_captured_reply(tempo_before, tempo_after) do
    base =
      "Capture ran but no new clip appeared in the Session grid. Live only buffers MIDI that " <>
        "was played *into* a track — the track has to be armed or monitoring its input — and " <>
        "the buffer is cleared by the previous capture, so there may be nothing left to keep. " <>
        "Audio can't be captured at all."

    if tempo_before == tempo_after do
      base <>
        " If Arrangement view was focused, Live may have captured there instead, where this " <>
        "tool can't see it."
    else
      base <>
        " Live did change the tempo (#{format_tempo(tempo_before)} → " <>
        "#{format_tempo(tempo_after)} BPM), so something *was* captured — most likely into " <>
        "Arrangement view, which Live captures into when that view is focused and which this " <>
        "tool can't see."
    end
  end

  @doc """
  How many beats `record_clip` should ask Live to record for a number of bars.

  `ClipSlot.fire`'s `record_length` is measured in Live's song-time beat, which
  is a quarter note regardless of the time signature — so a bar is
  `numerator × 4 / denominator` of them: four in 4/4, three in 3/4, but three
  (not six) in 6/8. Returns a float, which is what the OSC argument wants.

  ⚠️ The beat-unit assumption is unverified in odd meters (the 2026-07-29 raw-OSC
  check was 4/4, where the two conventions coincide). If Live turns out to count
  signature beats instead, this function is the one line to change.
  """
  @spec record_length_beats(number(), number(), number()) :: float()
  def record_length_beats(bars, numerator, denominator) do
    bars * numerator * 4 / denominator
  end

  @doc """
  `record_clip`'s `bars` against a song map, as `{:ok, beats}` or an error.

  `{:ok, nil}` for no `bars` — an open-ended take needs no signature and must
  keep working when the mirror is degraded. But converting bars to beats *does*
  need one, and a `nil` numerator or denominator would otherwise reach
  `record_length_beats/3` and raise `ArithmeticError` mid-tool-call. Refusing is
  better than recording a take of the wrong length off a guessed 4/4: the guard
  sits ahead of every OSC send in `record_clip`, so "nothing was recorded" is
  true when this errors.
  """
  @spec record_length_from(number() | nil, map()) :: {:ok, float() | nil} | {:error, String.t()}
  def record_length_from(nil, _song), do: {:ok, nil}

  def record_length_from(bars, %{time_sig_numerator: num, time_sig_denominator: den})
      when is_nil(num) or is_nil(den) do
    {:error,
     "The time signature isn't known (Ableton did not answer when the session was last " <>
       "read), so a #{bars}-bar length can't be converted to beats and nothing was recorded. " <>
       "Call get_session_state with refresh: true first, or omit bars to record open-ended " <>
       "and stop_recording when done."}
  end

  def record_length_from(bars, song) do
    {:ok, record_length_beats(bars, song.time_sig_numerator, song.time_sig_denominator)}
  end

  @range_params ~w(start_pitch pitch_span start_time time_span)

  @doc """
  Builds the optional range arguments for `/live/clip/get/notes`.

  AbletonOSC's handler is all-or-nothing: it raises unless it gets exactly zero
  or four range arguments. So one range param from the model means filling in
  the other three (the same defaults `remove_notes` uses), and no range params
  means sending none at all and letting AbletonOSC apply its own catch-all.
  """
  @spec note_range_args(map()) :: list()
  def note_range_args(params) do
    if Enum.any?(@range_params, &Map.has_key?(params, &1)) do
      [
        Map.get(params, "start_pitch", 0),
        Map.get(params, "pitch_span", 128),
        Map.get(params, "start_time", 0.0) / 1.0,
        Map.get(params, "time_span", 9999.0) / 1.0
      ]
    else
      []
    end
  end

  @doc """
  Formats one track's send levels, one per line, with the send letter and the
  return track each one feeds.

  The letter and the return name are both there because neither alone is enough:
  Live's UI labels the send "B", the user calls it "the delay", and the tools
  want the index.
  """
  @spec format_track_sends(integer(), [map()]) :: String.t()
  def format_track_sends(_track, []) do
    "This set has no return tracks, so no track has any sends. Create one with " <>
      "create_return_track, then load an effect onto it in Live."
  end

  def format_track_sends(track, sends) do
    lines =
      Enum.map_join(sends, "\n", fn s ->
        ~s{  send #{s.index} (#{send_letter(s.index)}) → "#{s.return}": } <>
          "#{format_number(s.value)}"
      end)

    "#{length(sends)} send(s) on track #{track}:\n\n#{lines}"
  end

  # Appended once to a whole `get_session_state` reply that contains any unknown
  # at all. One sentence for the reply, not one per field: the per-field strings
  # stay short so a half-degraded session doesn't drown the readable half, and
  # the *explanation* — why a value is missing and what to do — is worth saying
  # exactly once.
  @unknown_explanation "Unknown values mean Ableton did not answer when the mirror was last " <>
                         "read — pass refresh: true to re-read, and check Ableton is running " <>
                         "with AbletonOSC enabled."

  @doc """
  The whole `get_session_state` reply, from the four mirrored values.

  Composition lives here rather than in the caller because the "exactly one
  trailing explanation for the whole reply" rule is a property of the
  composition, not of any one formatter. It `or`s the formatters' `unknown?`
  flags rather than sniffing the composed text for the word "unknown", which
  would work right up until a track is legitimately named that.
  """
  @spec format_session_state(map(), [map()] | nil, [map()], map() | nil) :: String.t()
  def format_session_state(song, tracks, return_tracks, master) do
    {song_line, song_unknown?} = format_song_line(song)
    {track_summary, tracks_unknown?} = format_track_summary(tracks)
    return_summary = format_return_tracks(return_tracks, master)

    body = "#{song_line}\n\n#{track_summary}\n\n#{return_summary}"

    if song_unknown? or tracks_unknown? or returns_unknown?(return_tracks, master) do
      "#{body}\n\n#{@unknown_explanation}"
    else
      body
    end
  end

  # `master: nil` is both "the extension never answered" (so returns are
  # unavailable too) and "that one query was lost" — either way the reply says
  # something is missing, and the explanation belongs with it.
  defp returns_unknown?(_return_tracks, nil), do: true

  defp returns_unknown?(return_tracks, _master) do
    Enum.any?(return_tracks, &(is_nil(&1.name) or is_nil(&1.volume)))
  end

  @doc """
  The song line of `get_session_state`'s reply, plus whether any of it was
  unknown.

  Renders per field, so a lost tempo reply doesn't cost the time signature: only
  the phrase whose source is `nil` says "unknown". The caller owns the trailing
  explanation — see `format_session_state/4`.
  """
  @spec format_song_line(map()) :: {String.t(), boolean()}
  def format_song_line(song) do
    tempo = if is_nil(song.tempo), do: "tempo unknown", else: "#{song.tempo} BPM"

    signature_unknown? =
      is_nil(song.time_sig_numerator) or is_nil(song.time_sig_denominator)

    signature =
      if signature_unknown?,
        do: "time signature unknown",
        else: "#{song.time_sig_numerator}/#{song.time_sig_denominator}"

    playing =
      case song.is_playing do
        nil -> "playing state unknown"
        true -> "playing"
        false -> "stopped"
      end

    # Never `Pitch.pitch_class_name(nil)` — it quietly returns "", which would
    # print "key:  Major" and read as a key we simply forgot to name.
    key_unknown? = is_nil(song.root_note) or is_nil(song.scale_name)

    key =
      if key_unknown?,
        do: "key unknown",
        else: "key: #{Pitch.pitch_class_name(song.root_note)} #{song.scale_name}"

    unknown? =
      is_nil(song.tempo) or signature_unknown? or is_nil(song.is_playing) or key_unknown?

    {Enum.join([tempo, signature, playing, key], ", "), unknown?}
  end

  @doc """
  The per-track block of `get_session_state`'s reply, plus whether any of it was
  unknown.

  `nil` (the track list couldn't be read) and `[]` (a verified empty set) are
  deliberately different sentences: presenting an unreachable Ableton as a set
  with no tracks is the fabrication this whole path exists to stop.
  """
  @spec format_track_summary([map()] | nil) :: {String.t(), boolean()}
  def format_track_summary(nil) do
    {"The track list could not be read from Ableton — it is unknown, not empty. " <>
       "Pass refresh: true to re-read.", true}
  end

  def format_track_summary([]) do
    {"No tracks in current session (Ableton may not be connected)", false}
  end

  def format_track_summary(tracks) do
    formatted = Enum.map(tracks, &format_track_line/1)

    {Enum.map_join(formatted, "\n", &elem(&1, 0)), Enum.any?(formatted, &elem(&1, 1))}
  end

  defp format_track_line(t) do
    label =
      if is_nil(t.name),
        do: "Track #{t.index} (name unknown)",
        else: ~s{Track #{t.index} "#{t.name}"}

    pan = if is_nil(t.pan), do: "pan unknown", else: "pan=#{Float.round(t.pan / 1.0, 2)}"

    volume =
      if is_nil(t.volume), do: "volume unknown", else: "volume=#{Float.round(t.volume / 1.0, 2)}"

    mute = if t.mute == true, do: " [muted]", else: ""
    solo = if t.solo == true, do: " [solo]", else: ""

    # One marker for the pair: two unanswered flag queries are one lost refresh,
    # and "[mute unknown] [solo unknown]" is twice the noise for the same fact.
    flags_unknown? = is_nil(t.mute) or is_nil(t.solo)
    flags = if flags_unknown?, do: " [mute/solo unknown]", else: ""

    unknown? = is_nil(t.name) or is_nil(t.pan) or is_nil(t.volume) or flags_unknown?

    {"#{label}: #{pan}, #{volume}#{mute}#{solo}#{flags}", unknown?}
  end

  @doc """
  Formats the return tracks and the master level for `get_session_state`.

  `master` is `nil` when `/live/master/get/volume` never answered, which means
  Seshat's AbletonOSC extension isn't installed — say so rather than reporting a
  set with no returns, which looks identical but isn't. A single return's `name`
  or `volume` is `nil` on the same principle: one lost reply, and that field is
  unknown rather than "Return 1" or 0.85.
  """
  @spec format_return_tracks([map()], map() | nil) :: String.t()
  def format_return_tracks(_return_tracks, nil) do
    "Return/master state unavailable — run mix abletonosc.install and restart Live."
  end

  def format_return_tracks([], master) do
    "No return tracks in this set — nothing to send to yet; create one with " <>
      "create_return_track.\nMaster: volume=#{round_volume(master.volume)}"
  end

  def format_return_tracks(return_tracks, master) do
    lines =
      Enum.map_join(return_tracks, "\n", fn r ->
        "#{return_label(r)} (send #{send_letter(r.index)}): " <> volume_field(r.volume)
      end)

    "#{lines}\nMaster: volume=#{round_volume(master.volume)}"
  end

  defp return_label(%{name: nil, index: index}), do: "Return #{index} (name unknown)"
  defp return_label(r), do: ~s{Return #{r.index} "#{r.name}"}

  # A guessed fader position reads as real and the model does relative moves off
  # it ("turn the delay down a bit" from a fictional 0.85 is an increase), so an
  # unanswered volume query says so instead.
  defp volume_field(nil), do: "volume unknown (a reply was lost — try get_session_state again)"
  defp volume_field(value), do: "volume=#{round_volume(value)}"

  @doc """
  Send index → the letter Live's mixer prints on it: send 0 = A, send 1 = B.

  Live caps a set at 12 return tracks, so the alphabet never runs out in
  practice; past Z it falls back to the 1-based number rather than emitting
  punctuation.
  """
  @spec send_letter(non_neg_integer()) :: String.t()
  def send_letter(index) when index >= 0 and index < 26, do: <<?A + index>>
  def send_letter(index), do: "##{index + 1}"

  defp round_volume(value), do: Float.round(value / 1.0, 2)

  @doc """
  Approximate dB label for Live's 0.0–1.0 mixer scale.

  The fader is not linear and 1.0 is not the ceiling: ~0.85 is unity (0 dB) and
  1.0 is +6 dB. Across the useful top of the range the scale is close to linear
  in dB (`dB ≈ 40 × value − 34`), then dives toward silence below roughly 0.4 /
  −18 dB — so anything under that gets a bound rather than a misleading number.

  There is no OSC `value_string` for the mixer the way there is for device
  parameters, so this is computed rather than read back, and is labelled
  approximate wherever it is shown.
  """
  @spec volume_display(number()) :: String.t()
  def volume_display(value) when value <= 0.0, do: "silence"
  def volume_display(value) when value < 0.4, do: "≈ below -18 dB"
  def volume_display(value), do: "≈ #{format_db(40 * value - 34)}"

  defp format_db(db) do
    rounded = Float.round(db / 1.0, 1)
    magnitude = if rounded == trunc(rounded), do: trunc(rounded), else: rounded
    sign = if rounded > 0, do: "+", else: ""

    "#{sign}#{magnitude} dB"
  end

  @doc """
  Pan label in Live's own notation: `50L` (hard left), `C`, `50R` (hard right).

  Mirrors what the user reads off the mixer, so an echoed result can be checked
  against intent rather than against the raw -1.0…1.0 value.
  """
  @spec pan_display(number()) :: String.t()
  def pan_display(value) do
    amount = round(abs(value) * 50)

    cond do
      amount == 0 -> "C"
      value < 0 -> "#{amount}L"
      true -> "#{amount}R"
    end
  end

  defp device_type_label(1), do: "audio effect"
  defp device_type_label(2), do: "instrument"
  defp device_type_label(4), do: "MIDI effect"
  defp device_type_label(other), do: "type #{other}"

  defp format_number(value) when is_float(value), do: Float.round(value, 4)
  defp format_number(value), do: value

  defp do_call("set_track_pan", %{"track" => track, "value" => value}) do
    case Transport.send_message("/live/track/set/panning", [track, value / 1.0]) do
      :ok -> {:ok, "Set pan on track #{track} to #{value} (#{pan_display(value)})"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_track_volume", %{"track" => track, "value" => value}) do
    case Transport.send_message("/live/track/set/volume", [track, value / 1.0]) do
      :ok -> {:ok, "Set volume on track #{track} to #{value} (#{volume_display(value)})"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_track_mute", %{"track" => track, "muted" => muted}) do
    value = if muted, do: 1, else: 0

    case Transport.send_message("/live/track/set/mute", [track, value]) do
      :ok -> {:ok, "#{if muted, do: "Muted", else: "Unmuted"} track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_track_solo", %{"track" => track, "soloed" => soloed}) do
    value = if soloed, do: 1, else: 0

    case Transport.send_message("/live/track/set/solo", [track, value]) do
      :ok -> {:ok, "#{if soloed, do: "Soloed", else: "Unsoloed"} track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("create_track", %{"track_type" => type, "name" => name})
       when type in ["midi", "audio"] do
    command = %Command{command: :create_track, track_type: to_track_type(type), name: name}

    case Registry.execute(command) do
      {:ok, index} ->
        FollowCam.steer("create_track", %{track: index})
        {:ok, "Created #{type} track '#{name}' at index #{index}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # The track-type guard up front is the difference between an error and a lie:
  # AbletonOSC accepts a create_clip/add_notes sequence aimed at an audio track
  # and drops it on the floor, so without this the reply reports notes that were
  # never written.
  defp do_call("write_midi_notes", %{"track" => track, "notes" => notes} = params)
       when is_list(notes) and notes != [] do
    slot = Map.get(params, "clip_slot", 0)
    clip_length = Map.get(params, "clip_length", 4.0)

    parsed_notes =
      Enum.map(notes, fn n ->
        %{
          pitch: n["pitch"],
          start_beat: n["start_beat"] / 1.0,
          duration: n["duration"] / 1.0,
          velocity: n["velocity"]
        }
      end)

    command = %Command{
      command: :write_notes,
      track: track,
      clip_slot: slot,
      clip_length: clip_length,
      notes: parsed_notes
    }

    with :ok <- ensure_midi_track(track),
         :ok <- Registry.execute(command) do
      name = Map.get(params, "name")
      maybe_name_clip(track, slot, name)
      FollowCam.steer("write_midi_notes", %{track: track, slot: slot})

      note_count = length(parsed_notes)

      {:ok,
       "Wrote #{note_count} note(s) to track #{track}, clip slot #{slot}#{clip_name_note(name)}"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    # `ensure_midi_track/1` and Registry's own clip lookup each report their
    # timeout, so an exit reaching here came from one of the fire-and-forget
    # sends — the transport itself has stopped answering. Don't blame the indices
    # for that; and say what may be left behind, since the clip is created before
    # the notes are added. (`slot` is bound in the body, which the implicit try
    # can't see; only the head's params are in scope, so it is read back off
    # `params`.)
    :exit, _ ->
      {:error,
       "Lost contact with the OSC transport while writing to clip slot " <>
         "#{Map.get(params, "clip_slot", 0)} on track #{track}, so the notes were not written " <>
         "and an empty clip may have been left in the slot. Check that Ableton is running with " <>
         "AbletonOSC enabled, then try again."}
  end

  defp do_call("delete_track", %{"track" => track}) do
    case Transport.send_message("/live/song/delete_track", [track]) do
      :ok ->
        steer_after_delete("delete_track", %{track: track}, "/live/song/get/num_tracks")
        State.refresh()
        {:ok, "Deleted track #{track}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # ⚠️ Live placing the duplicate at source + 1 is the UI's behaviour and is
  # assumed here; it is a smoke-test item.
  defp do_call("duplicate_track", %{"track" => track}) do
    case Transport.send_message("/live/song/duplicate_track", [track]) do
      :ok ->
        FollowCam.steer("duplicate_track", %{track: track + 1})
        State.refresh()
        {:ok, "Duplicated track #{track} — the copy is track #{track + 1}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_call("set_track_name", %{"track" => track, "name" => name}) do
    case Transport.send_message("/live/track/set/name", [track, name]) do
      :ok -> {:ok, "Renamed track #{track} to '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_tempo", %{"bpm" => bpm}) do
    case Transport.send_message("/live/song/set/tempo", [bpm / 1.0]) do
      :ok -> {:ok, "Set tempo to #{bpm} BPM"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("start_playing", _params) do
    case Transport.send_message("/live/song/start_playing", []) do
      :ok -> {:ok, "Started playback"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("stop_playing", _params) do
    case Transport.send_message("/live/song/stop_playing", []) do
      :ok -> {:ok, "Stopped playback"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_metronome", %{"enabled" => enabled}) do
    value = if enabled, do: 1, else: 0

    case Transport.send_message("/live/song/set/metronome", [value]) do
      :ok -> {:ok, "Metronome #{if enabled, do: "on", else: "off"}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_track_arm", %{"track" => track, "armed" => armed}) do
    value = if armed, do: 1, else: 0

    case Transport.send_message("/live/track/set/arm", [track, value]) do
      :ok -> {:ok, "#{if armed, do: "Armed", else: "Disarmed"} track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # `/live/song/capture_midi` never replies: AbletonOSC's `_call_method` calls
  # `song.capture_midi()` and returns nothing, and it *catches* whatever the
  # call raises — so a capture with nothing buffered is exactly as silent as one
  # that worked. The only evidence available is the session itself, hence the
  # sandwich: snapshot the clip grid and the tempo before, fire, snapshot again,
  # and report the difference. Deliberately behaviour-agnostic — Live's
  # placement rules (which track, which slot, whether a scene gets added) are
  # observed rather than modelled.
  defp do_call("capture_midi", params) do
    with {:ok, tempo_before} <- query_tempo(),
         {:ok, before_grid} <- snapshot_grid() do
      fire_capture(tempo_before, before_grid, Map.get(params, "name"))
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the session before capturing, so nothing was sent. Check that " <>
         "Ableton is running with AbletonOSC enabled."}
  end

  # --- Session recording ---
  #
  # The deliberate take, and the only route audio has into a set. It rides on
  # `/live/clip_slot/fire`'s optional `record_length` (in beats): given one, Live
  # ends the take itself and leaves the clip looping; without one the take runs
  # until `stop_recording` re-fires the slot.
  #
  # Everything before the fire is a guard, because a fire is silent and every way
  # this goes wrong looks identical on the wire — an occupied slot *launches* that
  # clip, a disarmed track records nothing, a group track has no slots of its own.
  # Arming is done for the user rather than asked about: "record me a take on the
  # keys" is consent to arm, and the reply discloses it.
  #
  # `record_length/1` is placed before every OSC-issuing guard on purpose: it reads
  # `State.song()` directly, so it is the one step whose timeout is *not* already
  # turned into an `{:error, _}` by a query helper's own `catch`. Keeping it ahead
  # of `ensure_armed/1` keeps the realistic timeout — a session mirror that isn't
  # answering — from landing in the outer `catch` below with the track already
  # armed, since that catch's text says nothing was sent. It is not an absolute
  # guarantee: `Transport.send_message/2` is itself a `GenServer.call`, so a
  # transport that dies between the arm and the fire still reaches that clause.
  # Nothing cheaper distinguishes the two, and a dead transport has already made
  # the reply moot.
  #
  # Once the fire itself is sent, `report_record_started/5` is responsible for
  # never repeating that "nothing was sent" framing: `record_echo/2`'s own guard
  # errors still say it (they're shared with the pre-fire guards), so it rewraps
  # them instead of returning them verbatim.
  defp do_call("record_clip", %{"track" => track, "clip_slot" => slot} = params) do
    bars = Map.get(params, "bars")

    with :ok <- ensure_bars(bars),
         {:ok, beats} <- record_length(bars),
         :ok <- ensure_slot_empty(track, slot),
         {:ok, just_armed?} <- ensure_armed(track),
         :ok <- ensure_will_record(track, slot, just_armed?),
         :ok <- fire_for_record(track, slot, beats) do
      report_record_started(track, slot, bars, beats, just_armed?)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out checking the track and slot before recording, so nothing was sent. Check " <>
         "that Ableton is running with AbletonOSC enabled."}
  end

  # Finishing a take is a second fire at the *same* slot: Live ends the recording
  # at the next launch-quantization boundary and drops the clip into looped
  # playback. Both guards exist to stop that fire ever reaching an empty slot,
  # where the identical message would *start* a recording instead.
  defp do_call("stop_recording", %{"track" => track, "clip_slot" => slot}) do
    hint = " Nothing is recording there, and nothing was fired."

    with :ok <- ensure_clip(track, slot, hint),
         :ok <- ensure_recording(track, slot),
         :ok <- Transport.send_message("/live/clip_slot/fire", [track, slot]) do
      FollowCam.steer("stop_recording", %{track: track, slot: slot})

      {:ok,
       "Finishing the take in track #{track}, slot #{slot} — it ends at the next quantization " <>
         "boundary and keeps looping. get_clip_properties to inspect it (get_clip_notes too, " <>
         "if it's MIDI — an audio take has no notes to read); delete_clip to scrap it."}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Sends, return tracks, master ---
  #
  # Sends belong to the *regular* track that feeds the return, so they use
  # upstream's /live/track/get|set/send. Everything about the returns themselves
  # and the master comes from the fork's return_track.py — a Seshat extension, so
  # an un-run `mix abletonosc.install` means no reply at all rather than an
  # error. Each mutation therefore reads its own value back first: the guard is
  # the difference between an error and a lie.

  defp do_call("set_track_send", %{"track" => track, "send" => send_index, "value" => value}) do
    with {:ok, old} <-
           query_echoed(
             "/live/track/get/send",
             [track, send_index],
             "send #{send_index} on track #{track}",
             @send_index_hint
           ),
         :ok <-
           Transport.send_message("/live/track/set/send", [track, send_index, value / 1.0]) do
      {:ok,
       "Set send #{send_letter(send_index)}#{return_track_label(send_index)} on track " <>
         "#{track} to #{value} (was #{format_number(old)})"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("get_track_sends", %{"track" => track}) do
    with {:ok, count} <- return_track_count(),
         {:ok, sends} <- read_sends(track, count) do
      {:ok, format_track_sends(track, sends)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # The only multi-step one: create, then rename at the index the create appended
  # to. Registry owns the sequencing and hands back that index.
  defp do_call("create_return_track", %{"name" => name}) do
    case Registry.execute(%Command{command: :create_return_track, name: name}) do
      {:ok, index} ->
        FollowCam.steer("create_return_track", %{return: index})

        {:ok,
         ~s{Created return track "#{name}" (return #{index} — send #{send_letter(index)} on } <>
           "every track). It has no effect on it yet: Seshat cannot load a device onto a " <>
           "return track, so ask the user to drag one on in Live."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Guarded with get/name rather than get/count: one query catches a bad index and
  # a missing extension both, and the name is worth having in the reply.
  defp do_call("delete_return_track", %{"return_track" => index}) do
    with {:ok, name} <-
           query_echoed(
             "/live/return_track/get/name",
             [index],
             "return track #{index}",
             @return_extension_hint
           ),
         :ok <- Transport.send_message("/live/song/delete_return_track", [index]) do
      steer_after_delete(
        "delete_return_track",
        %{return: index},
        "/live/return_track/get/count"
      )

      State.refresh()

      {:ok,
       ~s{Deleted return track #{index} "#{name}". The returns after it have shifted down a } <>
         "place, taking their send letters with them — re-check get_session_state before " <>
         "touching another send."}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_return_track_volume", %{"return_track" => index, "value" => value}) do
    with {:ok, old} <-
           query_echoed(
             "/live/return_track/get/volume",
             [index],
             "the volume of return track #{index}",
             @return_extension_hint
           ),
         :ok <- Transport.send_message("/live/return_track/set/volume", [index, value / 1.0]) do
      # Label first, refresh second: `refresh/0` is a cast, so a `State` call made
      # after it queues behind the whole re-query and would time out into a blank
      # label on a slow refresh. The name doesn't change here anyway.
      label = return_track_label(index)
      State.refresh()

      {:ok,
       "Set volume on return track #{index}#{label} to #{value} " <>
         "(#{volume_display(value)}) — was #{format_number(old)} (#{volume_display(old)})"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_master_volume", %{"value" => value}) do
    with {:ok, old} <- master_volume(),
         :ok <- Transport.send_message("/live/master/set/volume", [value / 1.0]) do
      State.refresh()

      {:ok,
       "Set master volume to #{value} (#{volume_display(value)}) — was " <>
         "#{format_number(old)} (#{volume_display(old)})"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Undo / Redo ---

  defp do_call("undo", _params) do
    case Transport.send_message("/live/song/undo", []) do
      :ok -> {:ok, "Undone"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("redo", _params) do
    case Transport.send_message("/live/song/redo", []) do
      :ok -> {:ok, "Redone"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Clip control ---

  # Guarded because firing an empty slot is not a no-op: Live reads it as a stop
  # button and silences the track, so an unguarded typo looks like "fired" while
  # doing the opposite of what was asked.
  defp do_call("fire_clip", %{"track" => track, "clip_slot" => slot}) do
    hint =
      " Firing an empty slot would have stopped the track instead — if that was the intent, " <>
        "use stop_clip."

    with :ok <- ensure_clip(track, slot, hint),
         :ok <- Transport.send_message("/live/clip/fire", [track, slot]) do
      {:ok, "Fired clip on track #{track}, slot #{slot}"}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("stop_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip/stop", [track, slot]) do
      :ok -> {:ok, "Stopped clip on track #{track}, slot #{slot}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("delete_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip_slot/delete_clip", [track, slot]) do
      :ok ->
        FollowCam.steer("delete_clip", %{track: track, slot: slot})
        {:ok, "Deleted clip on track #{track}, slot #{slot}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_call("duplicate_clip", %{
         "track" => t,
         "clip_slot" => s,
         "target_track" => tt,
         "target_clip_slot" => ts
       }) do
    case Transport.send_message("/live/clip_slot/duplicate_clip_to", [t, s, tt, ts]) do
      :ok ->
        FollowCam.steer("duplicate_clip", %{track: tt, slot: ts})
        {:ok, "Duplicated clip from track #{t}/slot #{s} to track #{tt}/slot #{ts}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_call("set_clip_name", %{"track" => track, "clip_slot" => slot, "name" => name}) do
    case Transport.send_message("/live/clip/set/name", [track, slot, name]) do
      :ok -> {:ok, "Renamed clip on track #{track}, slot #{slot} to '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Clip properties ---
  #
  # Fourteen single-value getters rather than one bulk read: the bulk
  # `/live/song/get/track_data` reply is a bare value list with no index echo,
  # so it can't be checked against the clip we asked about (same reasoning as
  # `ensure_midi_track/1`), and these are sub-millisecond loopback round trips.
  # `ensure_clip/3` first so an empty slot costs one timeout-free error rather
  # than fourteen guard timeouts.
  defp do_call("get_clip_properties", %{"track" => track, "clip_slot" => slot}) do
    with :ok <- ensure_clip(track, slot),
         {:ok, midi?} <- clip_is_midi(track, slot),
         {:ok, common} <- read_clip_properties(track, slot, @clip_common_reads),
         {:ok, audio} <- read_audio_clip_properties(track, slot, midi?) do
      {:ok, format_clip_properties(track, slot, midi?, Map.merge(common, audio))}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the properties of the clip in slot #{slot} on track #{track}, so " <>
         "nothing is known about it. Check the indices with get_clip_slots, and that Ableton " <>
         "is running with AbletonOSC enabled."}
  end

  # Every clip setter is fire-and-forget — Live's own rejection of an invalid
  # state would be silent — so the honesty of this tool rests on three things:
  # transport-free validation up front, an ordered write list that never passes
  # through an invalid intermediate state (`clip_property_writes/2`), and a
  # read-back of every property written.
  defp do_call("set_clip_properties", %{"track" => track, "clip_slot" => slot} = params) do
    changes = Map.take(params, @clip_writable_properties)

    with :ok <- ensure_clip_changes(changes),
         :ok <- validate_clip_pairs(changes),
         :ok <- ensure_clip(track, slot),
         :ok <- ensure_audio_clip(track, slot, changes),
         {:ok, current} <- read_clip_pair_context(track, slot, changes),
         {:ok, writes} <- clip_property_writes(current, changes),
         :ok <- send_clip_writes(track, slot, writes),
         {:ok, readback} <- read_clip_writeback(track, slot, writes) do
      FollowCam.steer("set_clip_properties", %{track: track, slot: slot})
      {:ok, format_clip_writes(track, slot, current, writes, readback)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    # Everything before the sends reports its own timeout, so an exit reaching
    # here came from a fire-and-forget write or its read-back: the transport
    # itself has stopped answering, and some of the properties asked for may
    # already be applied. The write list isn't in scope in the implicit try —
    # only the head's params are — so the properties are named off `params`.
    :exit, _ ->
      {:error,
       "Lost contact with the OSC transport while setting " <>
         "#{clip_property_list(params)} on the clip in slot #{slot} on track #{track}. Some of " <>
         "those may already have been applied — check with get_clip_properties once Ableton is " <>
         "running with AbletonOSC enabled again."}
  end

  # --- Scene control ---

  defp do_call("fire_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/scene/fire", [scene]) do
      :ok -> {:ok, "Fired scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # `-1` means "append", so the new scene's index is only knowable afterwards —
  # hence the count read, which also lets the reply name the index the model will
  # need next. Best-effort like every follow-cam read: a miss falls back to the
  # unresolved wording rather than failing a create that succeeded.
  defp do_call("create_scene", %{"index" => index}) do
    case Transport.send_message("/live/song/create_scene", [index]) do
      :ok ->
        case created_scene_index(index) do
          {:ok, scene} ->
            FollowCam.steer("create_scene", %{scene: scene})
            {:ok, "Created scene at index #{scene}"}

          :error ->
            {:ok,
             "Created a scene at the end of the session — reading the scene count back to " <>
               "confirm its index timed out, so check get_clip_slots if you need it."}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_call("delete_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/delete_scene", [scene]) do
      :ok ->
        steer_after_delete("delete_scene", %{scene: scene}, "/live/song/get/num_scenes")
        {:ok, "Deleted scene #{scene}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # ⚠️ Live placing the copy at source + 1 is assumed, as in duplicate_track.
  defp do_call("duplicate_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/duplicate_scene", [scene]) do
      :ok ->
        FollowCam.steer("duplicate_scene", %{scene: scene + 1})
        {:ok, "Duplicated scene #{scene} — the copy is scene #{scene + 1}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_call("set_scene_name", %{"scene" => scene, "name" => name}) do
    case Transport.send_message("/live/scene/set/name", [scene, name]) do
      :ok -> {:ok, "Renamed scene #{scene} to '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Loop control ---

  defp do_call("set_loop", %{"enabled" => enabled} = params) do
    value = if enabled, do: 1, else: 0

    with :ok <- Transport.send_message("/live/song/set/loop", [value]),
         :ok <- maybe_set_loop_start(params),
         :ok <- maybe_set_loop_length(params) do
      {:ok, "Loop #{if enabled, do: "on", else: "off"}#{loop_range_summary(params)}"}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- View selection ---

  defp do_call("select_track", %{"track" => track}) do
    case Transport.send_message("/live/view/set/selected_track", [track]) do
      :ok -> {:ok, "Selected track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("select_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/view/set/selected_scene", [scene]) do
      :ok -> {:ok, "Selected scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Notes ---

  defp do_call("remove_notes", %{"track" => track} = params) do
    slot = Map.get(params, "clip_slot", 0)
    start_pitch = Map.get(params, "start_pitch", 0)
    pitch_span = Map.get(params, "pitch_span", 128)
    start_time = Map.get(params, "start_time", 0.0)
    time_span = Map.get(params, "time_span", 9999.0)

    case Transport.send_message("/live/clip/remove/notes", [
           track,
           slot,
           start_pitch,
           pitch_span,
           start_time / 1.0,
           time_span / 1.0
         ]) do
      :ok ->
        FollowCam.steer("remove_notes", %{track: track, slot: slot})
        {:ok, "Removed notes from track #{track}, clip slot #{slot}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Reads only, so no %Command{}/Registry — Registry is for mutation sequences.
  # The two guards up front are not politeness: querying notes on an empty slot
  # raises inside AbletonOSC, which means no reply and a 5s timeout instead of
  # an answer.
  defp do_call("get_clip_notes", %{"track" => track} = params) do
    slot = Map.get(params, "clip_slot", 0)

    with :ok <- ensure_clip(track, slot),
         :ok <- ensure_midi_clip(track, slot),
         {:ok, {_addr, [_t, _s, clip_name]}} <-
           Transport.query("/live/clip/get/name", [track, slot]),
         {:ok, {_addr, [_t, _s, clip_length]}} <-
           Transport.query("/live/clip/get/length", [track, slot]),
         {:ok, {_addr, [_t, _s | fields]}} <-
           Transport.query("/live/clip/get/notes", [track, slot | note_range_args(params)]),
         {:ok, notes} <- parse_clip_notes(fields) do
      {:ok, format_clip_notes(track, slot, clip_name, clip_length, notes)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    # `slot` is bound in the body, which the implicit try can't see — only the
    # head's params are in scope here.
    :exit, _ ->
      {:error,
       "Timed out reading the notes in slot #{Map.get(params, "clip_slot", 0)} on track " <>
         "#{track}. Check the track index against get_session_state, and that Ableton is " <>
         "running with AbletonOSC enabled."}
  end

  # --- Sound catalog ---
  #
  # Answered from ETS, so no Ableton required — see Seshat.Library.Catalog.

  defp do_call("search_library", params) do
    opts =
      [
        query: Map.get(params, "query"),
        tags: Map.get(params, "tags", []),
        category: Map.get(params, "category"),
        max_results: Map.get(params, "max_results", @default_catalog_results)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    if Catalog.count() == 0 do
      {:error,
       "The sound catalog is empty — it has never been built, or the build failed. Run " <>
         "reindex_library (Ableton must be running; it takes up to a minute), or fall back to " <>
         "list_browser_items for this search."}
    else
      {entries, total, facets} = Catalog.search(opts)

      # A zero-result search is the one case worth a second scan: without it the
      # reply can only say "loosen something", which is where the model gives up.
      context = if total == 0, do: Catalog.diagnose(opts), else: facets

      {:ok, format_catalog_entries(entries, total, context)}
    end
  end

  defp do_call("reindex_library", _params) do
    case Catalog.reindex() do
      {:ok, summary} ->
        {:ok, format_reindex_summary(summary)}

      {:error, reason} ->
        {:error, "Could not reindex the library: #{inspect(reason)}"}
    end
  catch
    :exit, _ ->
      {:error,
       "The browser export timed out. Is Ableton Live running with AbletonOSC enabled, and has " <>
         "`mix abletonosc.install` been run to add the browser handler? A very large library " <>
         "can also simply exceed the timeout — try again once Live has finished loading."}
  end

  # --- Browser / device loading ---
  #
  # Both addresses are Seshat extensions to AbletonOSC, served by the fork's
  # browser.py — see `mix abletonosc.install`.

  defp do_call("list_browser_items", %{"category" => category} = params) do
    filter = Map.get(params, "filter", "")
    max_results = Map.get(params, "max_results", @default_max_results)

    query =
      Transport.query(
        "/live/browser/get/items",
        [category, filter, max_results],
        @browse_timeout
      )

    case query do
      {:ok, {_address, [_category, _filter, "ok", _returned, total | pairs]}} ->
        {:ok, format_browser_items(pairs, total)}

      {:ok, {_address, [_category, _filter, "error", message]}} ->
        {:error, message}

      {:ok, {_address, args}} ->
        {:error, "Unexpected reply from Live's browser: #{inspect(args)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out searching Live's browser. The first search of a large category " <>
         "(samples, sounds, plugins) is slow — try again, or narrow it with a filter. " <>
         "If it keeps timing out, check that Ableton is running with AbletonOSC enabled and " <>
         "that `mix abletonosc.install` has been run to add the browser handler."}
  end

  defp do_call("load_device", %{"track" => track, "uri" => uri}) do
    case Transport.query("/live/browser/load_item", [track, uri], @load_timeout) do
      {:ok, {_address, [_track, _uri, "ok", name, device]}} ->
        Catalog.record_load(uri)
        FollowCam.steer("load_device", %{track: track, device: device})
        {:ok, "Loaded '#{name}' onto track #{track}#{loaded_device_note(device)}"}

      {:ok, {_address, [_track, _uri, "error", message]}} ->
        {:error, message}

      # The 4-element ok reply is the *previous* shape of this address, which is
      # our own — so seeing it means Live is running an older copy of the fork.
      # Not a compat path: a self-diagnosing refusal, since the device did load
      # and a silent degrade would hide why the view never followed.
      {:ok, {_address, [_track, _uri, "ok", name]}} ->
        {:error,
         "Loaded '#{name}' onto track #{track}, but Ableton is running an older copy of " <>
           "Seshat's AbletonOSC extension: its reply carries no device index, so the view " <>
           "can't follow the load. Run `mix abletonosc.install` and restart Ableton Live."}

      {:ok, {_address, args}} ->
        {:error, "Unexpected reply from Live's browser: #{inspect(args)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out loading the device onto track #{track}. A heavy plugin may still be " <>
         "loading — check Ableton, and use get_session_state before retrying so you don't " <>
         "load it twice."}
  end

  # --- Device chain / parameters ---

  defp do_call("get_track_devices", %{"track" => track}) do
    with {:ok, {_addr, [_track | names]}} <-
           Transport.query("/live/track/get/devices/name", [track]),
         {:ok, {_addr, [_track | types]}} <-
           Transport.query("/live/track/get/devices/type", [track]),
         {:ok, {_addr, [_track | classes]}} <-
           Transport.query("/live/track/get/devices/class_name", [track]) do
      {:ok, format_device_chain(track, names, types, classes)}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading devices on track #{track}. Check the track index against " <>
         "get_session_state, and that Ableton is running with AbletonOSC enabled."}
  end

  defp do_call("get_device_parameters", %{"track" => track, "device" => device}) do
    with {:ok, {_addr, [_t, _d, device_name]}} <-
           Transport.query("/live/device/get/name", [track, device]),
         {:ok, {_addr, [_t, _d | names]}} <-
           Transport.query("/live/device/get/parameters/name", [track, device]),
         {:ok, {_addr, [_t, _d | values]}} <-
           Transport.query("/live/device/get/parameters/value", [track, device]),
         {:ok, {_addr, [_t, _d | mins]}} <-
           Transport.query("/live/device/get/parameters/min", [track, device]),
         {:ok, {_addr, [_t, _d | maxes]}} <-
           Transport.query("/live/device/get/parameters/max", [track, device]) do
      {:ok, format_device_parameters(track, device, device_name, names, values, mins, maxes)}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading device #{device} on track #{track}. Check both indices with " <>
         "get_track_devices first."}
  end

  defp do_call("set_device_parameter", %{
         "track" => track,
         "device" => device,
         "parameter" => parameter,
         "value" => value
       }) do
    with :ok <-
           Transport.send_message(
             "/live/device/set/parameter/value",
             [track, device, parameter, value / 1.0]
           ),
         {:ok, {_addr, [_t, _d, _p, display]}} <-
           Transport.query("/live/device/get/parameter/value_string", [track, device, parameter]) do
      {:ok,
       "Set parameter #{parameter} of device #{device} on track #{track} to #{value} — " <>
         "it now reads '#{display}'"}
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "The set was sent but reading the value back timed out — verify the result with " <>
         "get_device_parameters."}
  end

  # `/live/track/delete_device` never replies — AbletonOSC's `_call_method`
  # returns nothing, and a bad device index raises inside the callback — so
  # success and failure are indistinguishable on the wire. Hence the sandwich:
  # read the chain first (which validates the track index, bounds-checks the
  # device index in Elixir, and captures the names for the reply), then re-read
  # the count afterwards as the only confirmation available.
  defp do_call("delete_device", %{"track" => track, "device" => device}) do
    with {:ok, names} <- read_device_names(track),
         {:ok, device} <- ensure_device_index(track, device, names),
         :ok <- Transport.send_message("/live/track/delete_device", [track, device]),
         :ok <- confirm_device_count(track, length(names) - 1) do
      FollowCam.steer("delete_device", %{
        track: track,
        device: device,
        remaining: length(names) - 1
      })

      {:ok, deleted_device_reply(track, device, names)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Parameter 0 of every Live device is its "Device On" switch, so bypass is a
  # parameter write — but only if that really is what parameter 0 holds on this
  # device. The display value is read *before* the write and the write refused
  # unless it reads On/Off, so a device that breaks the assumption gets a clean,
  # self-diagnosing error instead of a wrong parameter silently changed.
  defp do_call("bypass_device", %{"track" => track, "device" => device, "enabled" => enabled}) do
    subject = "device #{device} on track #{track}"

    with {:ok, name} <-
           query_echoed("/live/device/get/name", [track, device], subject, @device_index_hint),
         {:ok, prior} <-
           query_echoed(
             "/live/device/get/parameter/value_string",
             [track, device, 0],
             "the on/off switch of #{subject}",
             @device_index_hint
           ),
         :ok <- ensure_on_off_switch(name, prior) do
      set_device_enabled(track, device, name, enabled, prior)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # Reads only, so direct Transport.query — no %Command{}/Registry (Registry
  # is for mutation sequences). One bulk track_data query per batch of tracks
  # plus one tiny query per scene name; parsing and formatting are pure.
  defp do_call("get_clip_slots", _params) do
    case snapshot_grid() do
      {:ok, %{tracks: []}} ->
        {:ok, "No tracks in the session — the clip grid is empty."}

      {:ok, %{num_scenes: num_scenes, tracks: tracks}} ->
        case query_scene_names(num_scenes) do
          {:ok, scenes} -> {:ok, format_clip_slots(scenes, tracks)}
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the clip grid. Check that Ableton is running with AbletonOSC enabled."}
  end

  # State mirrors Ableton by push, so it is current without asking. `refresh` is
  # the backstop for what the listeners can't see (a lost UDP push, or two
  # identically named tracks swapping places) and blocks until the re-read is
  # done — hence sync rather than the fire-and-forget `State.refresh/0`, which
  # would serve the stale mirror it just asked to replace.
  defp do_call("get_session_state", params) do
    with :ok <- maybe_refresh(params) do
      serve_session_state()
    end
  end

  defp do_call(name, _params), do: {:error, "Unknown tool: #{name}"}

  # An explicit refresh that never completes is caught here rather than left to
  # `serve_session_state/0`'s own catch, which reports a mirror that didn't
  # answer. Both are honest errors now, but they are different errors: this one
  # knows the caller asked Ableton for fresh values and never got them, so it
  # names Ableton and AbletonOSC. The caller passed refresh: true because the
  # mirror looked wrong; that is the fault worth reporting.
  defp maybe_refresh(params) do
    if Map.get(params, "refresh", false), do: State.refresh_sync(), else: :ok
  catch
    :exit, _ ->
      {:error,
       "Refreshing from Ableton timed out. Check that Ableton is running with " <>
         "AbletonOSC enabled."}
  end

  # Reads the four mirrored values and hands them to the pure formatter. The exit
  # catch is a *mirror* that didn't answer — realistically it is mid-refresh
  # against an unresponsive Ableton, since `do_refresh/1` blocks the GenServer
  # for the length of every guard timeout it hits. Reporting that as an empty
  # session (which this used to do) is the same fabrication as a guessed tempo,
  # just wearing a different coat: the caller has no way to tell "I couldn't ask"
  # from "there is nothing there".
  defp serve_session_state do
    {:ok,
     format_session_state(State.song(), State.tracks(), State.return_tracks(), State.master())}
  catch
    :exit, _ ->
      {:error,
       "The session mirror did not answer — it may be mid-refresh against an unresponsive " <>
         "Ableton. Try again shortly, and check Ableton is running with AbletonOSC enabled."}
  end

  defp to_track_type("midi"), do: :midi
  defp to_track_type("audio"), do: :audio

  # The clip grid as structured data — shared by `get_clip_slots` (which then
  # reads scene names and formats) and `capture_midi` (which takes two of these
  # and diffs them). Scene *names* deliberately stay out: they cost one query
  # per scene, and the capture diff needs occupancy only, so folding them in
  # here would double a per-scene query burst for strings nobody reads.
  #
  # An empty session answers `{:ok, %{num_scenes: 0, tracks: []}}` rather than
  # an error — capture on an empty set is a legitimate nothing-appeared, not a
  # failure to read.
  defp snapshot_grid do
    with {:ok, {_addr, [num_tracks]}} <- Transport.query("/live/song/get/num_tracks", []),
         {:ok, {_addr, [num_scenes]}} <- Transport.query("/live/song/get/num_scenes", []) do
      snapshot_tracks(num_tracks, num_scenes)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp snapshot_tracks(num_tracks, num_scenes) when num_tracks < 1 or num_scenes < 1 do
    {:ok, %{num_scenes: 0, tracks: []}}
  end

  defp snapshot_tracks(num_tracks, num_scenes) do
    with {:ok, values} <- query_track_data(num_tracks, num_scenes),
         {:ok, tracks} <- parse_track_data(values, num_scenes, num_tracks) do
      {:ok, %{num_scenes: num_scenes, tracks: tracks}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Follow cam helpers ---
  #
  # The decision of *where* to steer is pure and lives in `Seshat.Tools.FollowCam`.
  # What's left here is gathering the one fact a delete needs — how many of that
  # kind of object are left — and the optional clip name.

  # Ordering matters: this query runs *before* the clause's own `State.refresh()`
  # cast, so its reply can't interleave with that explicit refresh's queries to
  # the same address (Transport correlates replies by address alone, with a
  # single `pending` slot — a second in-flight query to the same address steals
  # the first caller's reply). That does *not* cover every source of contention:
  # the delete itself makes `song_structure.py` push `/live/song/get/tracks`,
  # which `Session.State` turns into its own synchronous read of this same
  # address, independent of the cast below and capable of racing this query.
  # If that race is lost, this call reports `:error` (see `remaining_count/1`)
  # and steering is simply skipped for that delete — never a crash or a wrong
  # index. The steering sends themselves are fire-and-forget and race nothing.
  defp steer_after_delete(tool, facts, count_address) do
    case remaining_count(count_address) do
      {:ok, remaining} -> FollowCam.steer(tool, Map.put(facts, :remaining, remaining))
      :error -> :ok
    end
  end

  # Deliberately total: every failure — timeout, missing extension, a reply shape
  # we don't recognise — means "don't steer", never "fail the tool".
  defp remaining_count(address) do
    case Transport.query(address, [], @follow_cam_count_timeout) do
      {:ok, {_addr, [count]}} when is_integer(count) -> {:ok, count}
      _other -> :error
    end
  catch
    :exit, _ -> :error
  end

  # `-1` appends, so the new scene is the last one; any other index is where it
  # was inserted.
  defp created_scene_index(-1) do
    with {:ok, count} when count > 0 <- remaining_count("/live/song/get/num_scenes") do
      {:ok, count - 1}
    else
      _other -> :error
    end
  end

  defp created_scene_index(index), do: {:ok, index}

  defp maybe_name_clip(_track, _slot, nil), do: :ok

  # Fire-and-forget, like `set_clip_name`'s own send — but this runs *after* a
  # mutation (write_midi_notes, capture_midi) that already succeeded, inside a
  # function whose own `catch :exit` assumes nothing past that point can still
  # exit. Left uncaught, a dead/restarting Transport here would surface as the
  # enclosing tool's timeout message, denying a write or capture that actually
  # landed. Catch and log instead: worst case the clip keeps its default name.
  defp maybe_name_clip(track, slot, name) do
    case Transport.send_message("/live/clip/set/name", [track, slot, name]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "maybe_name_clip: /live/clip/set/name failed for track #{track}, slot #{slot}: " <>
            inspect(reason)
        )

        :ok
    end
  catch
    :exit, _ ->
      Logger.debug(
        "maybe_name_clip: transport unavailable, skipped naming clip at track #{track}, slot #{slot}"
      )

      :ok
  end

  defp clip_name_note(nil), do: ""
  defp clip_name_note(name), do: ~s{, named "#{name}"}

  defp loaded_device_note(-1), do: " (still instantiating, so it has no device index yet)"
  defp loaded_device_note(device), do: " (device #{device})"

  # --- capture_midi ---

  defp query_tempo do
    case Transport.query("/live/song/get/tempo", []) do
      {:ok, {_addr, [tempo]}} when is_number(tempo) ->
        {:ok, tempo}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/song/get/tempo: #{inspect(args)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Everything from here on runs *after* the capture message is on the wire, so
  # no failure text may imply nothing happened — the `set_device_parameter`
  # precedent. AbletonOSC processes datagrams in arrival order and
  # `song.capture_midi()` runs synchronously inside its callback, so the tempo
  # query sent afterwards reads the post-capture value.
  defp fire_capture(tempo_before, before_grid, name) do
    with :ok <- Transport.send_message("/live/song/capture_midi", []),
         {:ok, tempo_after} <- query_tempo(),
         {:ok, after_grid} <- snapshot_grid() do
      report_capture(before_grid, after_grid, tempo_before, tempo_after, name)
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Capture was sent but reading the session back timed out — check the result with " <>
         "get_clip_slots."}
  end

  defp report_capture(before_grid, after_grid, tempo_before, tempo_after, name) do
    case capture_diff(before_grid, after_grid) do
      {[], _scenes_added} ->
        retry_capture_diff(before_grid, tempo_before, tempo_after, name)

      {clips, scenes_added} ->
        captured_success(clips, scenes_added, tempo_before, tempo_after, name)
    end
  end

  # ⚠️ Unconfirmed whether Live has inserted the clip by the time the LOM call
  # returns — it may defer the insertion to a later UI tick. One bounded re-read
  # covers that case without turning a genuine nothing-captured into a stall.
  defp retry_capture_diff(before_grid, tempo_before, tempo_after, name) do
    Process.sleep(@capture_retry_delay)

    with {:ok, after_grid} <- snapshot_grid() do
      case capture_diff(before_grid, after_grid) do
        {[], _scenes_added} ->
          {:error, nothing_captured_reply(tempo_before, tempo_after)}

        {clips, scenes_added} ->
          captured_success(clips, scenes_added, tempo_before, tempo_after, name)
      end
    end
  end

  # One capture is one take, so a multi-track capture gets the same name on every
  # clip it produced. The name is substituted into the clip maps rather than
  # re-read: the after-snapshot predates the rename, so re-reading would cost a
  # round trip for a string we just wrote — the same trust `set_clip_name`
  # extends to its own fire-and-forget send.
  defp captured_success(clips, scenes_added, tempo_before, tempo_after, name) do
    clips = Enum.map(clips, &name_captured_clip(&1, name))
    steer_to_captured(clips)

    {:ok, captured_reply(clips, scenes_added, tempo_before, tempo_after)}
  end

  @doc """
  Applies `capture_midi`'s optional model-supplied `name` to one captured clip.

  Fires the rename (`maybe_name_clip/3`, itself exit-safe) and, independently
  of whether that send lands, substitutes the name into the returned map so
  `captured_reply/4` prints what was asked for rather than the `""` Live gave
  the clip by default.
  """
  @spec name_captured_clip(map(), String.t() | nil) :: map()
  def name_captured_clip(clip, nil), do: clip

  def name_captured_clip(%{track_index: track, slot_index: slot} = new_clip, name) do
    maybe_name_clip(track, slot, name)
    %{new_clip | clip: %{new_clip.clip | name: name}}
  end

  @doc """
  Which of `capture_midi`'s new clips gets the follow cam.

  Several new clips means one take spread across tracks; `clips` is already in
  track-then-slot order (`capture_diff/2`'s own ordering), so the first entry
  is the one to show. `nil` when nothing was captured.
  """
  @spec captured_steer_target([map()]) ::
          %{track: non_neg_integer(), slot: non_neg_integer()} | nil
  def captured_steer_target([%{track_index: track, slot_index: slot} | _rest]),
    do: %{track: track, slot: slot}

  def captured_steer_target([]), do: nil

  defp steer_to_captured(clips) do
    case captured_steer_target(clips) do
      nil -> :ok
      facts -> FollowCam.steer("capture_midi", facts)
    end
  end

  # No bulk scene-name address exists, so one query per scene — tiny replies,
  # fine at real-world scene counts.
  defp query_scene_names(num_scenes) do
    result =
      Enum.reduce_while(0..(num_scenes - 1), {:ok, []}, fn index, {:ok, acc} ->
        case Transport.query("/live/scene/get/name", [index]) do
          {:ok, {_addr, [_index, name]}} -> {:cont, {:ok, [name | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, names} <- result, do: {:ok, Enum.reverse(names)}
  end

  # end_track is exclusive; explicit bounds per batch (never -1) because
  # parsing needs the count anyway.
  defp query_track_data(num_tracks, num_scenes) do
    per_track = 3 + 5 * num_scenes
    batch_size = max(1, div(@track_data_target_values, per_track))

    result =
      0..(num_tracks - 1)
      |> Enum.chunk_every(batch_size)
      |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
        start_track = List.first(batch)
        end_track = List.last(batch) + 1
        args = [start_track, end_track | @track_data_properties]

        case Transport.query("/live/song/get/track_data", args) do
          {:ok, {_addr, values}} -> {:cont, {:ok, [values | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, batches} <- result do
      {:ok, batches |> Enum.reverse() |> Enum.concat()}
    end
  end

  # --- Session recording helpers ---

  defp ensure_bars(nil), do: :ok
  defp ensure_bars(bars) when is_number(bars) and bars > 0, do: :ok

  defp ensure_bars(bars) do
    {:error,
     "bars must be a positive number of bars (got #{inspect(bars)}), so nothing was " <>
       "recorded. Omit it for a take that runs until stop_recording."}
  end

  # The `nil` short-circuit stays here as well as inside `record_length_from/2`:
  # an open-ended take has no reason to need the mirror at all, and routing it
  # through `State.song()` would make a GenServer that is mid-refresh able to
  # fail a `record_clip` call that asks nothing of it.
  defp record_length(nil), do: {:ok, nil}
  defp record_length(bars), do: record_length_from(bars, State.song())

  # A third OSC argument is `ClipSlot.fire()`'s first optional positional one,
  # `record_length` — AbletonOSC's clip_slot handler forwards everything past the
  # two indices verbatim. Omitting it is what makes the take open-ended.
  defp fire_for_record(track, slot, nil) do
    Transport.send_message("/live/clip_slot/fire", [track, slot])
  end

  defp fire_for_record(track, slot, beats) do
    Transport.send_message("/live/clip_slot/fire", [track, slot, beats])
  end

  # The inverse of `ensure_clip/3`, and the reason `record_clip` is not just
  # `fire_clip` with a length: firing an *occupied* slot launches that clip
  # rather than recording anything, and says nothing about it.
  defp ensure_slot_empty(track, slot) do
    case query_flag(
           "/live/clip_slot/get/has_clip",
           [track, slot],
           "whether slot #{slot} on track #{track} holds a clip"
         ) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        {:error,
         "Slot #{slot} on track #{track} already holds a clip, so nothing was recorded — " <>
           "firing it would have launched that clip instead. Record into an empty slot " <>
           "(get_clip_slots shows which are free), or delete_clip this one first if the " <>
           "take is meant to replace it."}

      {:error, message} ->
        {:error, message}
    end
  end

  # Returns whether *this call* armed the track — `false` for one that was armed
  # already — so the reply can disclose an arm the user didn't ask for. A track
  # that is already armed skips the `can_be_armed` read: it self-evidently could.
  defp ensure_armed(track) do
    case query_flag("/live/track/get/arm", [track], "whether track #{track} is armed") do
      {:ok, true} -> {:ok, false}
      {:ok, false} -> arm_track(track)
      {:error, message} -> {:error, message}
    end
  end

  # `/live/track/set/arm` is silent, so the re-read is the whole guard: without
  # it a track Live refused to arm would go on to a fire that records nothing and
  # a reply claiming a take is running.
  defp arm_track(track) do
    case query_flag(
           "/live/track/get/can_be_armed",
           [track],
           "whether track #{track} can be armed"
         ) do
      {:ok, false} ->
        {:error,
         "Track #{track} can't be armed for recording, so nothing was recorded. Group tracks " <>
           "have no clip slots of their own — record into one of the tracks inside the " <>
           "group; get_clip_slots labels group tracks 'group'."}

      {:ok, true} ->
        with :ok <- Transport.send_message("/live/track/set/arm", [track, 1]),
             {:ok, armed?} <-
               query_flag("/live/track/get/arm", [track], "whether track #{track} is armed") do
          if armed? do
            {:ok, true}
          else
            {:error,
             "Asked Ableton to arm track #{track} but it still reads as disarmed, so nothing " <>
               "was recorded. Arm it by hand in Live — the round button in the track's mixer " <>
               "row — and try again."}
          end
        end

      {:error, message} ->
        {:error, message}
    end
  end

  # The definitive precondition, and the last one before anything is sent: Live
  # itself answering "would firing this slot record?". `just_armed?` is threaded
  # through so the false branch can disclose an arm this same call just made —
  # `ensure_armed/1`'s `/live/track/set/arm` already reached Live, so the track
  # is left armed (and monitoring possibly live) even though the fire never was.
  defp ensure_will_record(track, slot, just_armed?) do
    case query_flag(
           "/live/clip_slot/get/will_record_on_start",
           [track, slot],
           "whether firing slot #{slot} on track #{track} would record"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         "Live reports that firing slot #{slot} on track #{track} would not record, so no " <>
           "take was fired. The track is armed, so this is usually the track's input: check " <>
           "its input routing and monitoring in Live.#{armed_disclosure(just_armed?)}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp armed_disclosure(true) do
    " This call armed the track on the way in — disarm it with set_track_arm if that isn't wanted."
  end

  defp armed_disclosure(false), do: ""

  defp ensure_recording(track, slot) do
    case query_flag(
           "/live/clip/get/is_recording",
           [track, slot],
           "whether the clip in slot #{slot} on track #{track} is recording"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         "Nothing is recording in slot #{slot} on track #{track}, so nothing was fired — " <>
           "get_clip_slots marks the slot that is. Use stop_clip to stop a clip that is " <>
           "merely playing."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp report_record_started(track, slot, bars, beats, just_armed?) do
    case record_echo(track, slot) do
      {:ok, status} ->
        FollowCam.steer("record_clip", %{track: track, slot: slot})
        {:ok, record_reply(track, slot, bars, beats, just_armed?, status)}

      {:error, message} ->
        # `record_echo/2` shares its guard helpers with the pre-fire checks, so
        # its errors still carry their "nothing was sent" framing — false here,
        # since the fire already went out. Rewrap rather than return verbatim.
        {:error,
         "The take was fired on track #{track}, slot #{slot}, but confirming it failed: " <>
           "#{message} That doesn't mean nothing is recording — check with get_clip_slots, " <>
           "and stop_recording track #{track} slot #{slot} if it turns out to be running."}
    end
  end

  # The fire is silent, so the session itself is the only honest signal that the
  # take started. `has_clip` first: once Live has made the clip, `is_recording`
  # is definitive. Before that — a fire with the transport already playing waits
  # for the launch-quantization boundary — the evidence is slot-level
  # `is_triggered`. Deliberately no `playing_status`: its enum is documented
  # nowhere. Live handles datagrams in arrival order, so all three reads see a
  # session in which the fire has already been processed.
  defp record_echo(track, slot) do
    case query_flag(
           "/live/clip_slot/get/has_clip",
           [track, slot],
           "whether slot #{slot} on track #{track} holds a clip"
         ) do
      {:ok, true} -> recording_or_queued(track, slot)
      {:ok, false} -> queued_or_nothing(track, slot)
      {:error, message} -> {:error, message}
    end
  end

  defp recording_or_queued(track, slot) do
    case query_flag(
           "/live/clip/get/is_recording",
           [track, slot],
           "whether the clip in slot #{slot} on track #{track} is recording"
         ) do
      {:ok, true} -> {:ok, :recording}
      {:ok, false} -> queued_or_nothing(track, slot)
      {:error, message} -> {:error, message}
    end
  end

  defp queued_or_nothing(track, slot) do
    case query_flag(
           "/live/clip_slot/get/is_triggered",
           [track, slot],
           "whether slot #{slot} on track #{track} is waiting to start"
         ) do
      {:ok, true} ->
        {:ok, :queued}

      {:ok, false} ->
        {:error,
         "Fired slot #{slot} on track #{track} but Live reports nothing recording or waiting " <>
           "to start there, so the take did not begin. Live had just answered that firing " <>
           "this slot would record, so something changed underneath — most likely the slot " <>
           "or the track's arm was touched by hand in Live between the two. Check with " <>
           "get_clip_slots and call record_clip again."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp record_reply(track, slot, bars, beats, just_armed?, status) do
    [
      record_headline(track, slot, bars, beats),
      record_status_line(status),
      if(just_armed?, do: "Armed the track first.")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp record_headline(track, slot, nil, _beats) do
    "Recording into track #{track}, slot #{slot} until stop_recording."
  end

  defp record_headline(track, slot, bars, beats) do
    "Recording #{format_number(bars)} bars (#{format_number(beats)} beats) into track " <>
      "#{track}, slot #{slot} — Live stops the take itself and leaves the clip looping."
  end

  defp record_status_line(:recording), do: "Recording now."

  defp record_status_line(:queued) do
    "Queued: it starts at the next launch-quantization boundary, usually the next bar."
  end

  # --- Return tracks & master reads ---

  # Doubles as the "is return_track.py installed?" probe — the whole extension
  # either answers or it doesn't, so one timeout is enough to say which.
  defp return_track_count do
    case Transport.query("/live/return_track/get/count", [], @guard_timeout) do
      {:ok, {_addr, [count]}} when is_integer(count) ->
        {:ok, count}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/return_track/get/count: #{inspect(args)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ -> {:error, extension_missing_error("read the return tracks", "no sends were read")}
  end

  defp master_volume do
    case Transport.query("/live/master/get/volume", [], @guard_timeout) do
      {:ok, {_addr, [volume]}} when is_number(volume) ->
        {:ok, volume}

      {:ok, {_addr, args}} ->
        {:error, "Unexpected reply from /live/master/get/volume: #{inspect(args)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ -> {:error, extension_missing_error("read the master volume", "nothing was changed")}
  end

  defp extension_missing_error(attempted, consequence) do
    "Timed out trying to #{attempted}, so #{consequence}. Those addresses come from Seshat's " <>
      "AbletonOSC extension rather than upstream, so run `mix abletonosc.install` and restart " <>
      "Ableton Live — and check Live is running with AbletonOSC enabled."
  end

  # One name query per return plus one send query per return. Tiny replies, and
  # the return count is capped at 12 by Live.
  #
  # With no returns there are no sends to read, but the track index still gets
  # checked: otherwise a typo'd track comes back as "this set has no return
  # tracks" — true, and not the question that was asked.
  defp read_sends(track, count) when count < 1 do
    with {:ok, _name} <-
           query_echoed("/live/track/get/name", [track], "track #{track}", @track_index_hint) do
      {:ok, []}
    end
  end

  defp read_sends(track, count) do
    result =
      Enum.reduce_while(0..(count - 1), {:ok, []}, fn index, {:ok, acc} ->
        case read_send(track, index) do
          {:ok, send_data} -> {:cont, {:ok, [send_data | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, sends} <- result, do: {:ok, Enum.reverse(sends)}
  end

  defp read_send(track, index) do
    with {:ok, name} <-
           query_echoed(
             "/live/return_track/get/name",
             [index],
             "the name of return track #{index}",
             @return_extension_hint
           ),
         {:ok, value} <-
           query_echoed(
             "/live/track/get/send",
             [track, index],
             "send #{index} on track #{track}",
             @send_index_hint
           ) do
      {:ok, %{index: index, return: name, value: value}}
    end
  end

  # Best-effort label from the mirrored state, for a reply that reads better with
  # the return's name in it. Purely cosmetic, so a stale or unavailable mirror
  # costs nothing — and an *unknown* name (`nil`, its read unanswered) drops the
  # label entirely rather than rendering `("")`, which would present the return
  # as being named the empty string.
  defp return_track_label(index) do
    case Enum.find(State.return_tracks(), &(&1.index == index)) do
      %{name: nil} -> ""
      %{name: name} -> ~s{ ("#{name}")}
      _ -> ""
    end
  catch
    :exit, _ -> ""
  end

  # --- Device chain guards ---

  # The pre-delete read: it validates the track index and captures the chain in
  # one query. It can't ride `query_echoed/4` — that helper's `unwrap_payload/1`
  # only reads single-value payloads and this reply is a whole list — so the echo
  # check and its reissue-once stale defence are spelled out here for exactly the
  # same reason: Transport correlates replies by address alone, so a reply
  # abandoned by an earlier timeout can answer this query with another track's
  # chain.
  defp read_device_names(track, reissued? \\ false) do
    case Transport.query("/live/track/get/devices/name", [track], @guard_timeout) do
      {:ok, {_addr, [echoed | names]}} when echoed == track ->
        {:ok, names}

      {:ok, {_addr, _mismatched}} ->
        if reissued? do
          {:error, stale_reply_error("the devices on track #{track}")}
        else
          read_device_names(track, true)
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error, guard_timeout_error("the devices on track #{track}", @device_index_hint)}
  end

  # Floats are tolerated the way `query_echoed/5` documents for indices — 1.0
  # reaches Ableton as device 1 — so the bounds check normalises rather than
  # rejects, and hands back the index the rest of the sequence should use.
  defp ensure_device_index(track, device, names) do
    index = if is_number(device), do: trunc(device), else: device

    if is_integer(index) and index >= 0 and index < length(names) do
      {:ok, index}
    else
      {:error, device_out_of_range_error(track, device, names)}
    end
  end

  # The only defence the no-reply delete address allows. Raw `Transport.query`
  # deliberately, not `query_echoed/4`: that helper's timeout wording says
  # "nothing further was sent", which is false once the delete is on the wire —
  # a post-mutation confirmation needs its own wording (`set_device_parameter`'s
  # readback sets the precedent).
  defp confirm_device_count(track, expected) do
    case Transport.query("/live/track/get/num_devices", [track]) do
      {:ok, {_addr, [echoed, ^expected]}} when echoed == track ->
        :ok

      {:ok, {_addr, [echoed, actual]}} when echoed == track ->
        {:error,
         "The delete did not go through — track #{track} still reports #{actual} device(s), " <>
           "not #{expected}. Check Ableton and re-read the chain with get_track_devices."}

      {:ok, {_addr, args}} ->
        {:error,
         "The reply confirming the delete was not about track #{track} " <>
           "(got #{inspect(args)}) — likely left over from an earlier timed-out query, so it " <>
           "is unknown whether the device was removed. Verify with get_track_devices."}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "The delete was sent but confirming it timed out, so it is unknown whether the device " <>
         "was removed — verify with get_track_devices."}
  end

  # Steering happens on the no-op path too: showing the device is the
  # confirmation either way, and "it was already off" is exactly the answer a
  # user is most likely to want to see for themselves.
  defp set_device_enabled(track, device, name, enabled, prior) do
    if String.downcase(to_string(prior)) == String.downcase(on_off_label(enabled)) do
      FollowCam.steer("bypass_device", %{track: track, device: device})
      {:ok, bypass_noop_reply(name, track, device, enabled)}
    else
      with :ok <-
             Transport.send_message(
               "/live/device/set/parameter/value",
               [track, device, 0, if(enabled, do: 1.0, else: 0.0)]
             ),
           :ok <- confirm_device_enabled(track, device, enabled) do
        FollowCam.steer("bypass_device", %{track: track, device: device})
        {:ok, bypass_reply(name, track, device, enabled)}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  # Numeric readback rather than the display string: "Device On" is quantized to
  # exactly 0.0/1.0, so the comparison is safe, and it can't be confused by
  # however a given device chooses to spell its display value. Raw
  # `Transport.query` for the same reason as `confirm_device_count/2`.
  defp confirm_device_enabled(track, device, enabled) do
    expected = if enabled, do: 1.0, else: 0.0

    case Transport.query("/live/device/get/parameter/value", [track, device, 0]) do
      {:ok, {_addr, [t, d, p, value]}}
      when t == track and d == device and p == 0 and is_number(value) ->
        if value / 1.0 == expected do
          :ok
        else
          {:error,
           "The toggle was sent but device #{device} on track #{track} still reports its " <>
             "on/off parameter as #{format_number(value)}, not #{expected} — check it with " <>
             "get_device_parameters."}
        end

      {:ok, {_addr, args}} ->
        {:error,
         "The reply confirming the toggle was not about the on/off switch of device " <>
           "#{device} on track #{track} (got #{inspect(args)}) — likely left over from an " <>
           "earlier timed-out query. Verify with get_device_parameters."}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "The toggle was sent but reading it back timed out — verify with get_device_parameters."}
  end

  # --- Clip property helpers ---

  @doc """
  The ordered OSC writes for a `set_clip_properties` call.

  Pure, and the whole of the write-ordering decision — the handler around it
  only reads, sends and echoes. Takes the clip's current values (needed for the
  paired properties only) and the requested changes, both keyed by property
  name, and returns `[{property, wire_value}]` in the order they must go out.

  Ordering exists because clip setters are silent: Live requires `start < end`
  at all times, and a rejected write would produce no error, just a clip that
  didn't change. So the invariant has to hold after *every individual message*,
  not merely at the end:

    * `looping` goes first. While looping is off, Live's object model aliases
      `loop_start`/`loop_end` onto the play markers, so writing a brace before
      the toggle would move the wrong thing.
    * A pair with both sides changing is written end-first when the new start
      lies at or beyond the old end (`s1 >= e0`), start-first otherwise. Either
      way both intermediate states are valid.
    * A pair with one side changing must be valid against the *current* other
      side, or it is an error naming that current value — there is no ordering
      that can rescue it.
    * Unpaired scalars go last, in `@clip_scalar_properties` order.

  Values are coerced to the house wire conventions here too: booleans to 1/0,
  enums to integers, everything else to floats.
  """
  @spec clip_property_writes(map(), map()) ::
          {:ok, [{String.t(), number()}]} | {:error, String.t()}
  def clip_property_writes(current, changes) do
    with :ok <- validate_clip_pairs(changes),
         {:ok, loop_writes} <- clip_pair_writes(current, changes, "loop_start", "loop_end"),
         {:ok, marker_writes} <-
           clip_pair_writes(current, changes, "start_marker", "end_marker") do
      {:ok,
       clip_looping_write(changes) ++ loop_writes ++ marker_writes ++ clip_scalar_writes(changes)}
    end
  end

  # Runs twice: once in the handler before anything touches the transport (so an
  # inverted range costs no round trips at all), and once inside
  # `clip_property_writes/2` so the pure function is correct on its own terms.
  defp validate_clip_pairs(changes) do
    Enum.reduce_while(@clip_pair_properties, :ok, fn {start_key, end_key}, :ok ->
      case {Map.get(changes, start_key), Map.get(changes, end_key)} do
        {start, finish} when is_number(start) and is_number(finish) and start >= finish ->
          {:halt,
           {:error,
            "#{start_key} #{format_number(start / 1.0)} is not before #{end_key} " <>
              "#{format_number(finish / 1.0)} — a clip's range must start before it ends, so " <>
              "nothing was set."}}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp clip_pair_writes(current, changes, start_key, end_key) do
    case {Map.fetch(changes, start_key), Map.fetch(changes, end_key)} do
      {:error, :error} ->
        {:ok, []}

      {{:ok, start}, {:ok, finish}} ->
        {:ok, ordered_pair_writes(current, start_key, start, end_key, finish)}

      {{:ok, start}, :error} ->
        case Map.get(current, end_key) do
          finish when is_number(finish) and is_number(start) and start / 1.0 >= finish / 1.0 ->
            {:error,
             "#{start_key} #{format_number(start / 1.0)} is not before the current #{end_key} " <>
               "#{format_number(finish / 1.0)} — pass #{end_key} too to move the whole range. " <>
               "Nothing was set."}

          _ ->
            {:ok, [clip_write(start_key, start)]}
        end

      {:error, {:ok, finish}} ->
        case Map.get(current, start_key) do
          start when is_number(start) and is_number(finish) and finish / 1.0 <= start / 1.0 ->
            {:error,
             "#{end_key} #{format_number(finish / 1.0)} is not after the current #{start_key} " <>
               "#{format_number(start / 1.0)} — pass #{start_key} too to move the whole range. " <>
               "Nothing was set."}

          _ ->
            {:ok, [clip_write(end_key, finish)]}
        end
    end
  end

  # End-first when the new range sits at or beyond the old end, so the
  # intermediate state is (old start, new end) rather than the inverted
  # (new start, old end). With no current value known, start-first is the
  # harmless default.
  defp ordered_pair_writes(current, start_key, start, end_key, finish) do
    current_end = Map.get(current, end_key)

    if is_number(current_end) and is_number(start) and start / 1.0 >= current_end / 1.0 do
      [clip_write(end_key, finish), clip_write(start_key, start)]
    else
      [clip_write(start_key, start), clip_write(end_key, finish)]
    end
  end

  defp clip_looping_write(%{"looping" => value}), do: [clip_write("looping", value)]
  defp clip_looping_write(_changes), do: []

  defp clip_scalar_writes(changes) do
    @clip_scalar_properties
    |> Enum.filter(&Map.has_key?(changes, &1))
    |> Enum.map(&clip_write(&1, Map.fetch!(changes, &1)))
  end

  defp clip_write(property, value), do: {property, coerce_clip_value(property, value)}

  # `truthy?/1`, not a bare `if`: every non-nil term is truthy in Elixir, so a
  # model that spells a boolean as `0` — which `Seshat.Agent` passes through
  # unvalidated, MCP mode's Peri schema being the only thing that rejects it —
  # would otherwise turn the property *on*.
  defp coerce_clip_value(property, value) when property in @clip_boolean_properties,
    do: if(truthy?(value), do: 1, else: 0)

  defp coerce_clip_value(property, value)
       when property in @clip_integer_properties and is_number(value),
       do: trunc(value)

  defp coerce_clip_value(_property, value) when is_number(value), do: value / 1.0
  defp coerce_clip_value(_property, value), do: value

  defp ensure_clip_changes(changes) when map_size(changes) == 0 do
    {:error,
     "Nothing to set — pass at least one property: " <>
       Enum.join(@clip_writable_properties, ", ") <> "."}
  end

  defp ensure_clip_changes(_changes), do: :ok

  # Only pays for the type check when an audio-only property is actually being
  # written. An explicit error, never a silent drop — the `write_midi_notes`
  # guard precedent.
  defp ensure_audio_clip(track, slot, changes) do
    case Enum.filter(@clip_audio_only_properties, &Map.has_key?(changes, &1)) do
      [] ->
        :ok

      properties ->
        case clip_is_midi(track, slot) do
          {:ok, true} ->
            {:error,
             "#{Enum.join(properties, ", ")} apply to audio clips only, and slot #{slot} on " <>
               "track #{track} holds a MIDI clip — nothing was set. Drop those properties and " <>
               "try again."}

          {:ok, false} ->
            :ok

          {:error, message} ->
            {:error, message}
        end
    end
  end

  defp clip_is_midi(track, slot) do
    query_flag(
      "/live/clip/get/is_midi_clip",
      [track, slot],
      "whether the clip in slot #{slot} on track #{track} is MIDI"
    )
  end

  # Both sides of a pair, whenever either side is changing: the ordering
  # decision needs the current end, the single-sided validation needs the
  # current other side, and the echo reports "was".
  defp read_clip_pair_context(track, slot, changes) do
    @clip_pair_properties
    |> Enum.flat_map(fn {start_key, end_key} ->
      if Map.has_key?(changes, start_key) or Map.has_key?(changes, end_key),
        do: [start_key, end_key],
        else: []
    end)
    |> then(&read_clip_properties(track, slot, &1))
  end

  # Everything written, plus the two derived values worth seeing: the dB string
  # after a gain change (the 0–1 float's curve is undocumented, so the display
  # string is the only honest report), and the length after anything that moves
  # the clip's audible extent.
  #
  # A failure here is reported in this function's own words rather than passed
  # up: every `query_echoed/4` error ends in "nothing further was sent", which is
  # true of a guard that runs *before* the writes and false of a read-back that
  # runs after them. The writes are already on the wire at this point, and
  # telling the model otherwise is the one lie this tool can't afford — its whole
  # contract is that what it reports is what Live holds (`confirm_device_enabled`
  # draws the same distinction on the same kind of path).
  defp read_clip_writeback(track, slot, writes) do
    written = Enum.map(writes, fn {property, _value} -> property end)

    extras =
      if("gain" in written, do: ["gain_display_string"], else: []) ++
        if(Enum.any?(written, &(&1 in @clip_range_properties)), do: ["length"], else: [])

    case read_clip_properties(track, slot, written ++ extras) do
      {:ok, values} ->
        {:ok, values}

      {:error, _message} ->
        {:error,
         "#{Enum.join(written, ", ")} #{if(length(written) == 1, do: "was", else: "were")} sent " <>
           "to the clip in slot #{slot} on track #{track} and most likely applied, but reading " <>
           "the values back failed — what Live actually holds is unconfirmed. Check with " <>
           "get_clip_properties, and that Ableton is still running with AbletonOSC enabled."}
    end
  end

  defp read_audio_clip_properties(_track, _slot, true), do: {:ok, %{}}

  defp read_audio_clip_properties(track, slot, false),
    do: read_clip_properties(track, slot, @clip_audio_reads)

  defp read_clip_properties(track, slot, properties) do
    Enum.reduce_while(properties, {:ok, %{}}, fn property, {:ok, acc} ->
      case query_echoed(
             clip_get_address(property),
             [track, slot],
             "the #{property} of the clip in slot #{slot} on track #{track}",
             @clip_index_hint
           ) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, property, value)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp send_clip_writes(track, slot, writes) do
    Enum.reduce_while(writes, :ok, fn {property, value}, :ok ->
      case Transport.send_message(clip_set_address(property), [track, slot, value]) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            "Failed to set #{property} on the clip in slot #{slot} on track #{track}: " <>
              "#{inspect(reason)}. Properties earlier in the same call may already have been " <>
              "applied — check with get_clip_properties."}}
      end
    end)
  end

  # Addresses as literals, one clause per property, rather than interpolating
  # the property name into the address: `vendored_addresses_test` greps `lib/`
  # for `"/live/…"` literals, and an interpolated address is invisible to it.
  defp clip_get_address("name"), do: "/live/clip/get/name"
  defp clip_get_address("length"), do: "/live/clip/get/length"
  defp clip_get_address("looping"), do: "/live/clip/get/looping"
  defp clip_get_address("loop_start"), do: "/live/clip/get/loop_start"
  defp clip_get_address("loop_end"), do: "/live/clip/get/loop_end"
  defp clip_get_address("start_marker"), do: "/live/clip/get/start_marker"
  defp clip_get_address("end_marker"), do: "/live/clip/get/end_marker"
  defp clip_get_address("launch_mode"), do: "/live/clip/get/launch_mode"
  defp clip_get_address("launch_quantization"), do: "/live/clip/get/launch_quantization"
  defp clip_get_address("legato"), do: "/live/clip/get/legato"
  defp clip_get_address("velocity_amount"), do: "/live/clip/get/velocity_amount"
  defp clip_get_address("gain"), do: "/live/clip/get/gain"
  defp clip_get_address("gain_display_string"), do: "/live/clip/get/gain_display_string"
  defp clip_get_address("warp_mode"), do: "/live/clip/get/warp_mode"
  defp clip_get_address("warping"), do: "/live/clip/get/warping"

  defp clip_set_address("looping"), do: "/live/clip/set/looping"
  defp clip_set_address("loop_start"), do: "/live/clip/set/loop_start"
  defp clip_set_address("loop_end"), do: "/live/clip/set/loop_end"
  defp clip_set_address("start_marker"), do: "/live/clip/set/start_marker"
  defp clip_set_address("end_marker"), do: "/live/clip/set/end_marker"
  defp clip_set_address("launch_mode"), do: "/live/clip/set/launch_mode"
  defp clip_set_address("launch_quantization"), do: "/live/clip/set/launch_quantization"
  defp clip_set_address("legato"), do: "/live/clip/set/legato"
  defp clip_set_address("velocity_amount"), do: "/live/clip/set/velocity_amount"
  defp clip_set_address("gain"), do: "/live/clip/set/gain"
  defp clip_set_address("warp_mode"), do: "/live/clip/set/warp_mode"
  defp clip_set_address("warping"), do: "/live/clip/set/warping"

  # An *unwarped* audio clip counts its length, loop points and markers in
  # seconds, not beats (Live's object model switches the unit on `warping`), so
  # the reply names the unit it is actually reporting rather than always saying
  # "beats" and being wrong on exactly the clips a producer drags in.
  defp format_clip_properties(track, slot, midi?, properties) do
    type = if midi?, do: "MIDI", else: "audio"
    beats? = midi? or truthy?(properties["warping"])
    unit = if beats?, do: "beats", else: "seconds"
    position = if beats?, do: "beat", else: "second"

    header =
      "Clip '#{properties["name"]}' — track #{track}, slot #{slot} — #{type}, " <>
        "#{format_number(properties["length"])} #{unit}"

    loop =
      "Loop: #{on_off_word(truthy?(properties["looping"]))}, from #{position} " <>
        "#{format_number(properties["loop_start"])} to " <>
        "#{format_number(properties["loop_end"])}" <>
        beat_span(properties["loop_start"], properties["loop_end"], unit)

    markers =
      "Play markers: start #{format_number(properties["start_marker"])}, " <>
        "end #{format_number(properties["end_marker"])}"

    launch =
      "Launch: #{enum_name(@launch_mode_names, properties["launch_mode"])}, quantization " <>
        "#{enum_name(@launch_quantization_names, properties["launch_quantization"])}, legato " <>
        "#{on_off_word(truthy?(properties["legato"]))}, velocity amount " <>
        "#{format_number(properties["velocity_amount"])}"

    audio =
      if midi? do
        []
      else
        [
          "Audio: gain #{properties["gain_display_string"]} " <>
            "(#{format_number(properties["gain"])}), warp " <>
            "#{on_off_word(truthy?(properties["warping"]))}, mode " <>
            "#{enum_name(@warp_mode_names, properties["warp_mode"])}"
        ]
      end

    Enum.join([header, loop, markers, launch] ++ audio, "\n")
  end

  defp format_clip_writes(track, slot, current, writes, readback) do
    lines =
      Enum.map(writes, fn {property, sent} ->
        "  " <>
          clip_write_line(property, sent, Map.get(readback, property), Map.get(current, property))
      end)

    extras =
      [
        if(Map.has_key?(readback, "gain_display_string"),
          do: "  gain now reads #{readback["gain_display_string"]} in Live"
        ),
        if(Map.has_key?(readback, "length"),
          do: "  clip length is now #{format_number(readback["length"])} beats"
        )
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(
      ["Set clip properties on track #{track}, slot #{slot}:" | lines] ++ extras,
      "\n"
    )
  end

  # The read-back is the only place a silent in-Live rejection can surface, so a
  # value that came back different from what was sent is reported as such rather
  # than smoothed over.
  defp clip_write_line(property, sent, got, was) do
    previously = if is_nil(was), do: "", else: " (was #{format_clip_value(property, was)})"

    cond do
      is_nil(got) ->
        "#{property}: #{format_clip_value(property, sent)} was sent, but reading it back gave " <>
          "nothing#{previously}"

      clip_value_matches?(property, sent, got) ->
        "#{property}: #{format_clip_value(property, got)}#{previously}"

      true ->
        "#{property}: Live reports #{format_clip_value(property, got)}, not the " <>
          "#{format_clip_value(property, sent)} that was sent#{previously}"
    end
  end

  defp clip_value_matches?(property, sent, got) when property in @clip_boolean_properties,
    do: truthy?(got) == (sent == 1)

  defp clip_value_matches?(_property, sent, got) when is_number(sent) and is_number(got),
    do: Float.round(sent / 1.0, 4) == Float.round(got / 1.0, 4)

  defp clip_value_matches?(_property, sent, got), do: sent == got

  defp format_clip_value(property, value) when property in @clip_boolean_properties,
    do: on_off_word(truthy?(value))

  defp format_clip_value("launch_mode", value), do: enum_name(@launch_mode_names, value)

  defp format_clip_value("launch_quantization", value),
    do: enum_name(@launch_quantization_names, value)

  defp format_clip_value("warp_mode", value), do: enum_name(@warp_mode_names, value)
  defp format_clip_value(_property, value), do: format_number(value)

  defp clip_property_list(params) do
    case Enum.filter(@clip_writable_properties, &Map.has_key?(params, &1)) do
      [] -> "no properties"
      properties -> Enum.join(properties, ", ")
    end
  end

  defp beat_span(start, finish, unit) when is_number(start) and is_number(finish),
    do: " (#{format_number(finish / 1.0 - start / 1.0)} #{unit})"

  defp beat_span(_start, _finish, _unit), do: ""

  defp enum_name(names, value) do
    key = if is_number(value), do: trunc(value), else: value
    Map.get(names, key, "unknown (#{inspect(value)})")
  end

  defp on_off_word(true), do: "on"
  defp on_off_word(false), do: "off"

  # --- Guards ---
  #
  # Each guard catches its own timeout rather than leaving it to the caller: a
  # `catch` on the calling clause also covers the work that runs *after* the
  # guard, so a later timeout would come back wearing the guard's error message.
  # All four read a single flag through `query_flag/3`, which is where the
  # reply-correlation hazard is handled.

  # Message stays action-neutral: shared by the readers (get_clip_notes) and by
  # fire_clip. `hint` carries the caller's own advice about what an empty slot
  # means for *that* operation, and is appended only on the empty-slot branch —
  # a transport failure gets the bare reason, not misleading advice.
  defp ensure_clip(track, slot, hint \\ "") do
    case query_flag(
           "/live/clip_slot/get/has_clip",
           [track, slot],
           "whether slot #{slot} on track #{track} holds a clip"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         "Slot #{slot} on track #{track} is empty. Clip slots are 0-based, so scene 1 is " <>
           "slot 0; check the slot and track index with get_clip_slots." <> hint}

      {:error, message} ->
        {:error, message}
    end
  end

  # Two properties, not one: `has_midi_input` is true for a group track built
  # from MIDI tracks as well, and a group track has no clip slots of its own —
  # so without the second check the write is dropped and we report success,
  # which is the failure mode this guard exists to kill. Ordered so an audio
  # track still costs a single round trip.
  #
  # Two queries rather than one `/live/song/get/track_data` carrying both
  # properties: that reply is a bare value list with no index echo, so it cannot
  # be checked against the track we asked about. A second sub-millisecond
  # loopback round trip is the cheaper thing to spend.
  defp ensure_midi_track(track) do
    case query_flag("/live/track/get/has_midi_input", [track], "the type of track #{track}") do
      {:ok, true} ->
        ensure_not_group_track(track)

      {:ok, false} ->
        {:error,
         "Track #{track} is an audio track — MIDI notes can only be written to MIDI tracks, " <>
           "so nothing was written. Check track types with get_clip_slots, and remember " <>
           "track indices are 0-based."}

      {:error, message} ->
        {:error, message}
    end
  end

  defp ensure_not_group_track(track) do
    case query_flag(
           "/live/track/get/is_foldable",
           [track],
           "whether track #{track} is a group track"
         ) do
      {:ok, true} ->
        {:error,
         "Track #{track} is a group track — it has no clip slots of its own, so nothing was " <>
           "written. Write to one of the tracks inside the group instead; get_clip_slots " <>
           "labels group tracks 'group'."}

      {:ok, false} ->
        :ok

      {:error, message} ->
        {:error, message}
    end
  end

  defp ensure_midi_clip(track, slot) do
    case query_flag(
           "/live/clip/get/is_midi_clip",
           [track, slot],
           "whether the clip in slot #{slot} on track #{track} is MIDI"
         ) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        {:error,
         "The clip in slot #{slot} on track #{track} is an audio clip, not a MIDI clip, so " <>
           "it has no notes to read."}

      {:error, message} ->
        {:error, message}
    end
  end

  # `query_echoed/4` for the boolean properties, normalising AbletonOSC's mix of
  # `true`/`false` and 1/0.
  defp query_flag(address, indices, subject) do
    with {:ok, flag} <- query_echoed(address, indices, subject, @clip_index_hint) do
      {:ok, truthy?(flag)}
    end
  end

  # Reads one value, and returns it only if the reply echoed back the indices we
  # asked about. Transport correlates replies by address alone and keeps only one
  # query in flight, so a reply abandoned by an earlier timeout can land while a
  # later query for the same address is pending — answering a guard for track 3
  # with track 0's data is exactly the silent wrong answer these guards exist to
  # prevent.
  #
  # A mismatch reissues the query once rather than failing outright: consuming the
  # stale reply also clears Transport's `pending`, so our own answer is usually
  # already on the wire behind it and the second ask lands cleanly. Only a second
  # mismatch is reported.
  #
  # Indices are compared with `==` rather than pinned: a float index still reaches
  # Ableton fine (it casts to int) and comes back as an integer, so pinning would
  # reject a reply that is in fact ours.
  #
  # `hint` is the caller's advice for a timeout — which index to re-check, and
  # whether the address is one of Seshat's extensions.
  defp query_echoed(address, indices, subject, hint, reissued? \\ false) do
    case Transport.query(address, indices, @guard_timeout) do
      {:ok, {_addr, values}} ->
        {echoed, payload} = Enum.split(values, length(indices))

        if indices_match?(echoed, indices) do
          case unwrap_payload(payload) do
            {:ok, value} -> {:ok, value}
            {:error, message} -> {:error, remote_error(message)}
            :unexpected_shape -> reissue_or_give_up(address, indices, subject, hint, reissued?)
          end
        else
          reissue_or_give_up(address, indices, subject, hint, reissued?)
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  catch
    :exit, _ -> {:error, guard_timeout_error(subject, hint)}
  end

  @doc """
  Reads the value out of a getter reply, once the echoed indices have been
  stripped off the front.

  Upstream getters reply with the value alone. Seshat's own return/master getters
  wrap it in browser.py's ok/error envelope, so an index that doesn't exist comes
  back as a message instead of the silence upstream produces — immediately, and
  distinguishably from an extension that was never installed.

  `:unexpected_shape` means the reply is not one this code knows how to read,
  which the caller treats as a crossed wire rather than an answer.
  """
  @spec unwrap_payload(list()) :: {:ok, term()} | {:error, String.t()} | :unexpected_shape
  def unwrap_payload([value]), do: {:ok, value}
  def unwrap_payload(["ok", value]), do: {:ok, value}
  def unwrap_payload(["error", message]) when is_binary(message), do: {:error, message}
  def unwrap_payload(_other), do: :unexpected_shape

  defp remote_error(message) do
    "#{message}. Nothing further was sent — check get_session_state for the indices that " <>
      "actually exist."
  end

  defp reissue_or_give_up(address, indices, subject, hint, false),
    do: query_echoed(address, indices, subject, hint, true)

  defp reissue_or_give_up(_address, _indices, subject, _hint, true),
    do: {:error, stale_reply_error(subject)}

  defp indices_match?(echoed, indices) do
    echoed |> Enum.zip(indices) |> Enum.all?(fn {reply, asked} -> reply == asked end)
  end

  # What a timeout means depends on who serves the address, so the caller's hint
  # supplies the diagnosis: for upstream addresses silence is usually a bad index,
  # for Seshat's own extension it can only be a missing install.
  defp guard_timeout_error(subject, hint) do
    "Timed out checking #{subject}, so nothing further was sent. #{hint}"
  end

  # Reissued once already, so this is not one crossed wire: something is steadily
  # answering with another index's data.
  defp stale_reply_error(subject) do
    "Ableton's replies when checking #{subject} were not about the track or slot asked for, " <>
      "twice in a row — they belong to an earlier query that timed out. Nothing further was " <>
      "sent; try again."
  end

  # AbletonOSC sends booleans for some properties and 0/1 for others.
  defp truthy?(true), do: true
  defp truthy?(value) when is_number(value), do: value != 0
  defp truthy?(_value), do: false

  defp maybe_set_loop_start(%{"start" => start}),
    do: Transport.send_message("/live/song/set/loop_start", [start / 1.0])

  defp maybe_set_loop_start(_), do: :ok

  defp maybe_set_loop_length(%{"length" => length}),
    do: Transport.send_message("/live/song/set/loop_length", [length / 1.0])

  defp maybe_set_loop_length(_), do: :ok

  defp loop_range_summary(%{"start" => start, "length" => length}),
    do: " — start: #{start}, length: #{length} beats"

  defp loop_range_summary(%{"start" => start}), do: " — start: #{start}"
  defp loop_range_summary(%{"length" => length}), do: " — length: #{length} beats"
  defp loop_range_summary(_), do: ""
end
