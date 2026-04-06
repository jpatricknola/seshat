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
    command = %Command{command: :create_track, track_type: String.to_existing_atom(type), name: name}

    case Registry.execute(command) do
      :ok -> {:ok, "Created #{type} track '#{name}'"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call("create_project", %{"tracks" => tracks}) when is_list(tracks) do
    parsed_tracks =
      Enum.map(tracks, fn %{"track_type" => type, "name" => name} ->
        %{track_type: String.to_existing_atom(type), name: name}
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
  end

  def call(name, _params), do: {:error, "Unknown tool: #{name}"}

  defp execute(%Command{} = command) do
    case Registry.execute(command) do
      :ok ->
        {:ok, "OK — #{command.command} track #{command.track} to #{command.value}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end
end
