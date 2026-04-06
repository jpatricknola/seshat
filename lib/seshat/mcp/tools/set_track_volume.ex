defmodule Seshat.MCP.Tools.SetTrackVolume do
  @moduledoc "Set the volume level of a track in Ableton Live. Track indices are 0-based: 'track 1' = index 0. Value ranges from 0.0 (silence) to 1.0 (full volume)."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response

  schema do
    field :track, {:required, :integer}, description: "0-indexed track number. 'Track 1' = 0."
    field :value, {:required, :float}, description: "Volume level. 0.0 = silence, 1.0 = full volume"
  end

  @impl true
  def execute(params, frame) do
    case Seshat.Tools.Handlers.call("set_track_volume", params) do
      {:ok, msg} -> {:reply, Response.tool() |> Response.text(msg), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end
end
