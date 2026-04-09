defmodule Seshat.MCP.Tools.SetTrackPan do
  @moduledoc "Set the stereo panning position of a track in Ableton Live. Track indices are 0-based: 'track 1' = index 0. Value ranges from -1.0 (full left) through 0.0 (center) to 1.0 (full right)."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response

  schema do
    field :track, {:required, :integer}, description: "0-indexed track number. 'Track 1' = 0."
    field :value, {:required, :float}, description: "Pan position. -1.0 = full left, 0.0 = center, 1.0 = full right"
  end

  @impl true
  def execute(params, frame) do
    case Seshat.Tools.Handlers.call("set_track_pan", params) do
      {:ok, msg} -> {:reply, Response.tool() |> Response.text(msg), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end
end
