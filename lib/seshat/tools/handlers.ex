defmodule Seshat.Tools.Handlers do
  @moduledoc """
  Dispatches tool calls to their implementations.

  Shared by both MCP and API key modes. Takes a tool name and input map and
  returns a result suitable for sending back to the LLM. Single-message tools
  talk to `Seshat.OSC.Transport` directly; multi-step sequences (create_track,
  write_midi_notes, create_project) build a `%Command{}` and execute it via
  `Seshat.Commands.Registry`.
  """

  alias Seshat.Commands.{Command, Registry}
  alias Seshat.Library.Catalog
  alias Seshat.Music.Pitch
  alias Seshat.OSC.Transport
  alias Seshat.Session.State

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

  # The return/master addresses are Seshat's own, and they always reply — a bad
  # index comes back as an error envelope, not silence. So unlike the upstream
  # families above, a timeout here isn't a bad index at all: it means nothing is
  # serving the address.
  @return_extension_hint "These addresses come from Seshat's AbletonOSC extension rather than " <>
                           "upstream, and it answers every query it receives — even for an index " <>
                           "that doesn't exist. Silence therefore means it isn't installed: run " <>
                           "`mix abletonosc.install` and restart Ableton Live, and check Live is " <>
                           "running with AbletonOSC enabled."

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
            "#{format_tag_counts(facets)}. Add one as a tag to narrow."
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
      [] -> ""
      notes -> " " <> Enum.join(notes, " ") <> " " <> retry_advice(diagnosis)
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

  @doc """
  Formats the return tracks and the master level for `get_session_state`.

  `master` is `nil` when `/live/master/get/volume` never answered, which means
  Seshat's AbletonOSC extension isn't installed — say so rather than reporting a
  set with no returns, which looks identical but isn't. A single return's
  `volume` is `nil` on the same principle: one lost reply, and the fader position
  is unknown rather than 0.85.
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
        ~s{Return #{r.index} "#{r.name}" (send #{send_letter(r.index)}): } <>
          volume_field(r.volume)
      end)

    "#{lines}\nMaster: volume=#{round_volume(master.volume)}"
  end

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
      :ok -> {:ok, "Created #{type} track '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("create_project", %{"tracks" => tracks}) when is_list(tracks) do
    parsed_tracks =
      Enum.map(tracks, fn %{"track_type" => type, "name" => name} ->
        %{track_type: to_track_type(type), name: name}
      end)

    command = %Command{command: :new_project, tracks: parsed_tracks}

    case Registry.execute(command) do
      :ok ->
        names = Enum.map_join(parsed_tracks, ", ", & &1.name)
        {:ok, "Created new project with tracks: #{names}"}

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
      note_count = length(parsed_notes)
      {:ok, "Wrote #{note_count} note(s) to track #{track}, clip slot #{slot}"}
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
        State.refresh()
        {:ok, "Deleted track #{track}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp do_call("duplicate_track", %{"track" => track}) do
    case Transport.send_message("/live/song/duplicate_track", [track]) do
      :ok ->
        State.refresh()
        {:ok, "Duplicated track #{track}"}

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

  # --- Sends, return tracks, master ---
  #
  # Sends belong to the *regular* track that feeds the return, so they use
  # upstream's /live/track/get|set/send. Everything about the returns themselves
  # and the master comes from priv/abletonosc/return_track.py — a Seshat
  # extension, so an un-run `mix abletonosc.install` means no reply at all rather
  # than an error. Each mutation therefore reads its own value back first: the
  # guard is the difference between an error and a lie.

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
      :ok -> {:ok, "Deleted clip on track #{track}, slot #{slot}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("duplicate_clip", %{
         "track" => t,
         "clip_slot" => s,
         "target_track" => tt,
         "target_clip_slot" => ts
       }) do
    case Transport.send_message("/live/clip_slot/duplicate_clip_to", [t, s, tt, ts]) do
      :ok -> {:ok, "Duplicated clip from track #{t}/slot #{s} to track #{tt}/slot #{ts}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_clip_name", %{"track" => track, "clip_slot" => slot, "name" => name}) do
    case Transport.send_message("/live/clip/set/name", [track, slot, name]) do
      :ok -> {:ok, "Renamed clip on track #{track}, slot #{slot} to '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Scene control ---

  defp do_call("fire_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/scene/fire", [scene]) do
      :ok -> {:ok, "Fired scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("create_scene", %{"index" => index}) do
    case Transport.send_message("/live/song/create_scene", [index]) do
      :ok -> {:ok, "Created scene at index #{index}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("delete_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/delete_scene", [scene]) do
      :ok -> {:ok, "Deleted scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("duplicate_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/duplicate_scene", [scene]) do
      :ok -> {:ok, "Duplicated scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
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
      :ok -> {:ok, "Removed notes from track #{track}, clip slot #{slot}"}
      {:error, reason} -> {:error, inspect(reason)}
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
  # Both addresses are Seshat extensions to AbletonOSC, served by
  # priv/abletonosc/browser.py — see `mix abletonosc.install`.

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
      {:ok, {_address, [_track, _uri, "ok", name]}} ->
        Catalog.record_load(uri)
        {:ok, "Loaded '#{name}' onto track #{track}"}

      {:ok, {_address, [_track, _uri, "error", message]}} ->
        {:error, message}

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

  # Reads only, so direct Transport.query — no %Command{}/Registry (Registry
  # is for mutation sequences). One bulk track_data query per batch of tracks
  # plus one tiny query per scene name; parsing and formatting are pure.
  defp do_call("get_clip_slots", _params) do
    with {:ok, {_addr, [num_tracks]}} <- Transport.query("/live/song/get/num_tracks", []),
         {:ok, {_addr, [num_scenes]}} <- Transport.query("/live/song/get/num_scenes", []) do
      read_clip_grid(num_tracks, num_scenes)
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  catch
    :exit, _ ->
      {:error,
       "Timed out reading the clip grid. Check that Ableton is running with AbletonOSC enabled."}
  end

  defp do_call("get_session_state", _params) do
    song = State.song()
    tracks = State.tracks()

    playing = if song.is_playing, do: "playing", else: "stopped"

    song_line =
      "#{song.tempo} BPM, #{song.time_sig_numerator}/#{song.time_sig_denominator}, #{playing}, " <>
        "key: #{Pitch.pitch_class_name(song.root_note)} #{song.scale_name}"

    track_summary =
      if tracks == [] do
        "No tracks in current session (Ableton may not be connected)"
      else
        Enum.map_join(tracks, "\n", fn t ->
          mute = if t.mute, do: " [muted]", else: ""
          solo = if t.solo, do: " [solo]", else: ""

          "Track #{t.index} \"#{t.name}\": pan=#{Float.round(t.pan, 2)}, " <>
            "volume=#{Float.round(t.volume, 2)}#{mute}#{solo}"
        end)
      end

    return_summary = format_return_tracks(State.return_tracks(), State.master())

    {:ok, "#{song_line}\n\n#{track_summary}\n\n#{return_summary}"}
  catch
    :exit, _ ->
      {:ok, "No tracks in current session (Ableton may not be connected)"}
  end

  defp do_call(name, _params), do: {:error, "Unknown tool: #{name}"}

  defp to_track_type("midi"), do: :midi
  defp to_track_type("audio"), do: :audio

  defp read_clip_grid(num_tracks, num_scenes) when num_tracks < 1 or num_scenes < 1 do
    {:ok, "No tracks in the session — the clip grid is empty."}
  end

  defp read_clip_grid(num_tracks, num_scenes) do
    with {:ok, scenes} <- query_scene_names(num_scenes),
         {:ok, values} <- query_track_data(num_tracks, num_scenes),
         {:ok, tracks} <- parse_track_data(values, num_scenes, num_tracks) do
      {:ok, format_clip_slots(scenes, tracks)}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
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
  # costs nothing.
  defp return_track_label(index) do
    case Enum.find(State.return_tracks(), &(&1.index == index)) do
      %{name: name} -> ~s{ ("#{name}")}
      _ -> ""
    end
  catch
    :exit, _ -> ""
  end

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
  defp truthy?(value) when is_integer(value), do: value != 0
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
