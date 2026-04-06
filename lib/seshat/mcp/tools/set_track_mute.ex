defmodule Seshat.MCP.Tools.SetTrackMute do
  @moduledoc "Mute or unmute a track in Ableton Live. Track indices are 0-based: 'track 1' = index 0."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response

  schema do
    field :track, {:required, :integer}, description: "0-indexed track number. 'Track 1' = 0."
    field :muted, {:required, :boolean}, description: "true = muted, false = unmuted"
  end

  @impl true
  def execute(params, frame) do
    case Seshat.Tools.Handlers.call("set_track_mute", params) do
      {:ok, msg} -> {:reply, Response.tool() |> Response.text(msg), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end
end
