defmodule Seshat.MCP.Server do
  @moduledoc """
  MCP server exposing Ableton Live control tools.

  Clients (e.g. Claude Desktop) connect via stdio or SSE and can discover
  and call tools for mixing, track creation, and session queries.
  """

  use Hermes.Server,
    name: "seshat",
    version: "0.1.0",
    capabilities: [:tools]

  component Seshat.MCP.Tools.SetTrackPan
  component Seshat.MCP.Tools.SetTrackVolume
  component Seshat.MCP.Tools.SetTrackMute
  component Seshat.MCP.Tools.SetTrackSolo
  component Seshat.MCP.Tools.CreateTrack
  component Seshat.MCP.Tools.CreateProject
  component Seshat.MCP.Tools.GetSessionState
end
