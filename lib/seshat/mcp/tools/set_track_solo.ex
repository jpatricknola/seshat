defmodule Seshat.MCP.Tools.SetTrackSolo do
  @moduledoc "Solo or unsolo a track in Ableton Live. Track indices are 0-based: 'track 1' = index 0."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response

  schema do
    field :track, {:required, :integer}, description: "0-indexed track number. 'Track 1' = 0."
    field :soloed, {:required, :boolean}, description: "true = soloed, false = unsoloed"
  end

  @impl true
  def execute(params, frame) do
    case Seshat.Tools.Handlers.call("set_track_solo", params) do
      {:ok, msg} -> {:reply, Response.tool() |> Response.text(msg), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end
end
