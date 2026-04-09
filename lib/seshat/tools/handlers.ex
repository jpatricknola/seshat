defmodule Seshat.Tools.Handlers do
  @moduledoc """
  Dispatches tool calls to the command registry.

  Shared by both MCP and API key modes. Takes a tool name and input map,
  builds the appropriate Command struct, executes it via Registry, and
  returns a result suitable for sending back to the LLM.
  """

  alias Seshat.Commands.{Command, Registry}
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

  def call("get_session_state", _params) do
    tracks = State.tracks()

    if tracks == [] do
      {:ok, "No tracks in current session (Ableton may not be connected)"}
    else
      summary =
        Enum.map_join(tracks, "\n", fn t ->
          mute = if t.mute, do: " [muted]", else: ""
          solo = if t.solo, do: " [solo]", else: ""

          "Track #{t.index} \"#{t.name}\": pan=#{Float.round(t.pan, 2)}, " <>
            "volume=#{Float.round(t.volume, 2)}#{mute}#{solo}"
        end)

      {:ok, summary}
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
end
