defmodule Seshat.MCP.Tools.CreateProject do
  @moduledoc "Start a new Ableton Live project with a set of tracks. Opens a fresh set and creates the specified tracks. Use 'midi' for software instruments, 'audio' for external recording."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response

  schema do
    embeds_many :tracks, required: true, description: "List of tracks to create" do
      field :track_type, {:required, :string}, description: "midi or audio"
      field :name, {:required, :string}, description: "Short descriptive label"
    end
  end

  @impl true
  def execute(params, frame) do
    case Seshat.Tools.Handlers.call("create_project", params) do
      {:ok, msg} -> {:reply, Response.tool() |> Response.text(msg), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end
end
