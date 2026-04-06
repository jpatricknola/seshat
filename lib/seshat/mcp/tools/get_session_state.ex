defmodule Seshat.MCP.Tools.GetSessionState do
  @moduledoc "Get the current state of all tracks in the Ableton Live session. Returns track names, indices, volume, pan, mute, and solo status. Use this before making relative adjustments or when you need to know what tracks exist."

  use Hermes.Server.Component, type: :tool

  alias Hermes.Server.Response

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Seshat.Tools.Handlers.call("get_session_state", %{}) do
      {:ok, msg} -> {:reply, Response.tool() |> Response.text(msg), frame}
      {:error, reason} -> {:reply, Response.tool() |> Response.error(reason), frame}
    end
  end
end
