defmodule Seshat.Tools.Handlers do
  @moduledoc """
  Dispatches tool calls to the command registry.

  Shared by both MCP and API key modes. Takes a tool name and input map,
  builds the appropriate Command struct, executes it via Registry, and
  returns a result suitable for sending back to the LLM.
  """

  alias Seshat.Commands.{Command, Registry}
  alias Seshat.OSC.Transport
  alias Seshat.Session.State

  # Browsing and loading are both far slower than a property read: the first
  # walk of a big browser category takes seconds, and a heavy plugin can take
  # tens of seconds to instantiate.
  @browse_timeout 15_000
  @load_timeout 30_000

  @default_max_results 25

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
  Formats the flat `[name, uri, name, uri, ...]` tail of a `/live/browser/get/items`
  reply into one line per item.

  `total` is how many items matched before truncation, so the model can tell
  "that's all of them" from "there are more, narrow the filter".
  """
  @spec format_browser_items(list(), non_neg_integer()) :: String.t()
  def format_browser_items([], _total) do
    "No matching browser items. Try a shorter filter, a different spelling, or another category."
  end

  def format_browser_items(pairs, total) do
    items = Enum.chunk_every(pairs, 2, 2, :discard)
    listing = Enum.map_join(items, "\n", fn [name, uri] -> "#{name} — uri: #{uri}" end)

    header =
      if length(items) < total do
        "Showing #{length(items)} of #{total} matches — refine the filter to see the rest."
      else
        "#{length(items)} match(es):"
      end

    "#{header}\n\n#{listing}"
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

  defp device_type_label(1), do: "audio effect"
  defp device_type_label(2), do: "instrument"
  defp device_type_label(4), do: "MIDI effect"
  defp device_type_label(other), do: "type #{other}"

  defp format_number(value) when is_float(value), do: Float.round(value, 4)
  defp format_number(value), do: value

  defp do_call("set_track_pan", %{"track" => track, "value" => value}) do
    execute(%Command{command: :pan, track: track, value: value / 1.0})
  end

  defp do_call("set_track_volume", %{"track" => track, "value" => value}) do
    execute(%Command{command: :volume, track: track, value: value / 1.0})
  end

  defp do_call("set_track_mute", %{"track" => track, "muted" => muted}) do
    value = if muted, do: 1.0, else: 0.0
    execute(%Command{command: :mute, track: track, value: value})
  end

  defp do_call("set_track_solo", %{"track" => track, "soloed" => soloed}) do
    value = if soloed, do: 1.0, else: 0.0
    execute(%Command{command: :solo, track: track, value: value})
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
      "#{song.tempo} BPM, #{song.time_sig_numerator}/#{song.time_sig_denominator}, #{playing}"

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

  defp execute(%Command{} = command) do
    case Registry.execute(command) do
      :ok ->
        {:ok, "OK — #{command.command} track #{command.track} to #{command.value}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

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
