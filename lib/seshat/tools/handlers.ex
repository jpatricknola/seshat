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

  @default_max_results 25
  @default_catalog_results 15

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
  Formats catalog entries as `name — tags [path] (uri)`, one per line.

  The tags are the whole reason to prefer this over a raw browser listing, so
  they lead; the uri trails because it is for the next tool call, not the user.
  """
  @spec format_catalog_entries([map()], non_neg_integer()) :: String.t()
  def format_catalog_entries([], _total) do
    "No catalog matches. Loosen the tags first (they must all match), then the query, then the " <>
      "category. If the catalog has never been built, run reindex_library."
  end

  def format_catalog_entries(entries, total) do
    listing =
      Enum.map_join(entries, "\n", fn entry ->
        "#{entry.name} — #{format_tags(entry.tags)}#{format_path(entry.path)} (#{entry.uri})"
      end)

    header =
      if length(entries) < total do
        "Showing #{length(entries)} of #{total} matches — narrow the query or add a tag to see " <>
          "the most relevant ones."
      else
        "#{length(entries)} match(es):"
      end

    "#{header}\n\n#{listing}"
  end

  defp format_tags([]), do: "no tags"
  defp format_tags(tags), do: Enum.join(tags, ", ")

  defp format_path(path) when path in [nil, ""], do: ""
  defp format_path(path), do: " [#{path}]"

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

  defp device_type_label(1), do: "audio effect"
  defp device_type_label(2), do: "instrument"
  defp device_type_label(4), do: "MIDI effect"
  defp device_type_label(other), do: "type #{other}"

  defp format_number(value) when is_float(value), do: Float.round(value, 4)
  defp format_number(value), do: value

  defp do_call("set_track_pan", %{"track" => track, "value" => value}) do
    case Transport.send_message("/live/track/set/panning", [track, value / 1.0]) do
      :ok -> {:ok, "Set pan on track #{track} to #{value}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_call("set_track_volume", %{"track" => track, "value" => value}) do
    case Transport.send_message("/live/track/set/volume", [track, value / 1.0]) do
      :ok -> {:ok, "Set volume on track #{track} to #{value}"}
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

    case Registry.execute(command) do
      :ok ->
        note_count = length(parsed_notes)
        {:ok, "Wrote #{note_count} note(s) to track #{track}, clip slot #{slot}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
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

  defp do_call("fire_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip/fire", [track, slot]) do
      :ok -> {:ok, "Fired clip on track #{track}, slot #{slot}"}
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
      {entries, total} = Catalog.search(opts)
      {:ok, format_catalog_entries(entries, total)}
    end
  end

  defp do_call("reindex_library", _params) do
    case Catalog.reindex() do
      {:ok, %{items: items, tagged: tagged}} ->
        {:ok,
         "Reindexed the sound catalog: #{items} item(s), #{tagged} of them tagged by Ableton. " <>
           "search_library is ready."}

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

  defp do_call("get_session_state", _params) do
    song = State.song()
    tracks = State.tracks()

    playing = if song.is_playing, do: "playing", else: "stopped"

    song_line =
      "#{song.tempo} BPM, #{song.time_sig_numerator}/#{song.time_sig_denominator}, #{playing}, " <>
        "key: #{Pitch.pitch_class_name(song.root_note)} #{song.scale_name}"

    if tracks == [] do
      {:ok, "#{song_line}\n\nNo tracks in current session (Ableton may not be connected)"}
    else
      track_summary =
        Enum.map_join(tracks, "\n", fn t ->
          mute = if t.mute, do: " [muted]", else: ""
          solo = if t.solo, do: " [solo]", else: ""

          "Track #{t.index} \"#{t.name}\": pan=#{Float.round(t.pan, 2)}, " <>
            "volume=#{Float.round(t.volume, 2)}#{mute}#{solo}"
        end)

      {:ok, "#{song_line}\n\n#{track_summary}"}
    end
  catch
    :exit, _ ->
      {:ok, "No tracks in current session (Ableton may not be connected)"}
  end

  defp do_call(name, _params), do: {:error, "Unknown tool: #{name}"}

  defp to_track_type("midi"), do: :midi
  defp to_track_type("audio"), do: :audio

  defp ensure_clip(track, slot) do
    case Transport.query("/live/clip_slot/get/has_clip", [track, slot]) do
      {:ok, {_addr, [_t, _s, has_clip]}} ->
        if truthy?(has_clip) do
          :ok
        else
          {:error,
           "No clip in slot #{slot} on track #{track} — there is nothing to read. Clip slots " <>
             "are 0-based, so scene 1 is slot 0; check the track index with get_session_state."}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp ensure_midi_clip(track, slot) do
    case Transport.query("/live/clip/get/is_midi_clip", [track, slot]) do
      {:ok, {_addr, [_t, _s, is_midi]}} ->
        if truthy?(is_midi) do
          :ok
        else
          {:error,
           "The clip in slot #{slot} on track #{track} is an audio clip, not a MIDI clip, so " <>
             "it has no notes to read."}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
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
