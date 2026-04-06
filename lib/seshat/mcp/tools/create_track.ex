defmodule Seshat.MCP.Tools.CreateTrack do
  @moduledoc "Create a new track in Ableton Live. Use 'midi' for software instruments (synths, samplers, drum machines). Use 'audio' for recording external sources (vocals, guitar, bass)."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response

  schema do
    field :track_type, {:required, :string}, description: "midi = software instruments, audio = external recording"
    field :name, {:required, :string}, description: "Short descriptive label for the track (e.g. 'Drums', 'Lead Synth')"
  end

  @impl true
  def execute(params, frame) do
    case Seshat.Tools.Handlers.call("create_track", params) do
      {:ok, msg} -> {:reply, Response.tool() |> Response.text(msg), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end
end
