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

  @spec call(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}

  def call("set_track_pan", %{"track" => track, "value" => value}) do
    execute(%Command{command: :pan, track: track, value: value / 1.0})
  end

  def call("set_track_volume", %{"track" => track, "value" => value}) do
    execute(%Command{command: :volume, track: track, value: value / 1.0})
  end

  def call("set_track_mute", %{"track" => track, "muted" => muted}) do
    value = if muted, do: 1.0, else: 0.0
    execute(%Command{command: :mute, track: track, value: value})
  end

  def call("set_track_solo", %{"track" => track, "soloed" => soloed}) do
    value = if soloed, do: 1.0, else: 0.0
    execute(%Command{command: :solo, track: track, value: value})
  end

  def call("create_track", %{"track_type" => type, "name" => name})
      when type in ["midi", "audio"] do
    command = %Command{command: :create_track, track_type: to_track_type(type), name: name}

    case Registry.execute(command) do
      :ok -> {:ok, "Created #{type} track '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("create_project", %{"tracks" => tracks}) when is_list(tracks) do
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

  def call("write_midi_notes", %{"track" => track, "notes" => notes} = params)
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

  def call("delete_track", %{"track" => track}) do
    case Transport.send_message("/live/song/delete_track", [track]) do
      :ok ->
        State.refresh()
        {:ok, "Deleted track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("duplicate_track", %{"track" => track}) do
    case Transport.send_message("/live/song/duplicate_track", [track]) do
      :ok ->
        State.refresh()
        {:ok, "Duplicated track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("set_track_name", %{"track" => track, "name" => name}) do
    case Transport.send_message("/live/track/set/name", [track, name]) do
      :ok -> {:ok, "Renamed track #{track} to '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("set_tempo", %{"bpm" => bpm}) do
    case Transport.send_message("/live/song/set/tempo", [bpm / 1.0]) do
      :ok -> {:ok, "Set tempo to #{bpm} BPM"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("start_playing", _params) do
    case Transport.send_message("/live/song/start_playing", []) do
      :ok -> {:ok, "Started playback"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("stop_playing", _params) do
    case Transport.send_message("/live/song/stop_playing", []) do
      :ok -> {:ok, "Stopped playback"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("set_metronome", %{"enabled" => enabled}) do
    value = if enabled, do: 1, else: 0
    case Transport.send_message("/live/song/set/metronome", [value]) do
      :ok -> {:ok, "Metronome #{if enabled, do: "on", else: "off"}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("set_track_arm", %{"track" => track, "armed" => armed}) do
    value = if armed, do: 1, else: 0
    case Transport.send_message("/live/track/set/arm", [track, value]) do
      :ok -> {:ok, "#{if armed, do: "Armed", else: "Disarmed"} track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Undo / Redo ---

  def call("undo", _params) do
    case Transport.send_message("/live/song/undo", []) do
      :ok -> {:ok, "Undone"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("redo", _params) do
    case Transport.send_message("/live/song/redo", []) do
      :ok -> {:ok, "Redone"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Clip control ---

  def call("fire_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip/fire", [track, slot]) do
      :ok -> {:ok, "Fired clip on track #{track}, slot #{slot}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("stop_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip/stop", [track, slot]) do
      :ok -> {:ok, "Stopped clip on track #{track}, slot #{slot}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("delete_clip", %{"track" => track, "clip_slot" => slot}) do
    case Transport.send_message("/live/clip_slot/delete_clip", [track, slot]) do
      :ok -> {:ok, "Deleted clip on track #{track}, slot #{slot}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("duplicate_clip", %{"track" => t, "clip_slot" => s, "target_track" => tt, "target_clip_slot" => ts}) do
    case Transport.send_message("/live/clip_slot/duplicate_clip_to", [t, s, tt, ts]) do
      :ok -> {:ok, "Duplicated clip from track #{t}/slot #{s} to track #{tt}/slot #{ts}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("set_clip_name", %{"track" => track, "clip_slot" => slot, "name" => name}) do
    case Transport.send_message("/live/clip/set/name", [track, slot, name]) do
      :ok -> {:ok, "Renamed clip on track #{track}, slot #{slot} to '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Scene control ---

  def call("fire_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/scene/fire", [scene]) do
      :ok -> {:ok, "Fired scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("create_scene", %{"index" => index}) do
    case Transport.send_message("/live/song/create_scene", [index]) do
      :ok -> {:ok, "Created scene at index #{index}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("delete_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/delete_scene", [scene]) do
      :ok -> {:ok, "Deleted scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("duplicate_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/song/duplicate_scene", [scene]) do
      :ok -> {:ok, "Duplicated scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("set_scene_name", %{"scene" => scene, "name" => name}) do
    case Transport.send_message("/live/scene/set/name", [scene, name]) do
      :ok -> {:ok, "Renamed scene #{scene} to '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Loop control ---

  def call("set_loop", %{"enabled" => enabled} = params) do
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

  def call("select_track", %{"track" => track}) do
    case Transport.send_message("/live/view/set/selected_track", [track]) do
      :ok -> {:ok, "Selected track #{track}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("select_scene", %{"scene" => scene}) do
    case Transport.send_message("/live/view/set/selected_scene", [scene]) do
      :ok -> {:ok, "Selected scene #{scene}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # --- Notes ---

  def call("remove_notes", %{"track" => track} = params) do
    slot = Map.get(params, "clip_slot", 0)
    start_pitch = Map.get(params, "start_pitch", 0)
    pitch_span = Map.get(params, "pitch_span", 128)
    start_time = Map.get(params, "start_time", 0.0)
    time_span = Map.get(params, "time_span", 9999.0)

    case Transport.send_message("/live/clip/remove/notes", [track, slot, start_pitch, pitch_span, start_time / 1.0, time_span / 1.0]) do
      :ok -> {:ok, "Removed notes from track #{track}, clip slot #{slot}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("get_session_state", _params) do
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

  def call(name, _params), do: {:error, "Unknown tool: #{name}"}

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

  defp maybe_set_loop_start(%{"start" => start}), do: Transport.send_message("/live/song/set/loop_start", [start / 1.0])
  defp maybe_set_loop_start(_), do: :ok

  defp maybe_set_loop_length(%{"length" => length}), do: Transport.send_message("/live/song/set/loop_length", [length / 1.0])
  defp maybe_set_loop_length(_), do: :ok

  defp loop_range_summary(%{"start" => start, "length" => length}), do: " — start: #{start}, length: #{length} beats"
  defp loop_range_summary(%{"start" => start}), do: " — start: #{start}"
  defp loop_range_summary(%{"length" => length}), do: " — length: #{length} beats"
  defp loop_range_summary(_), do: ""
end
