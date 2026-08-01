defmodule SeshatWeb.Router do
  use Phoenix.Router, helpers: false

  # Seshat has no OAuth. Clients probe for it anyway before falling back to an
  # unauthenticated connection, so answer explicitly rather than letting an
  # expected probe raise NoRouteError. See the plug's moduledoc.
  scope "/.well-known" do
    match :*, "/*path", SeshatWeb.Plugs.NoAuthDiscovery, []
  end

  # No `:accepts` pipeline here on purpose. Streamable HTTP serves two content
  # types on one path — `POST /mcp` carries JSON-RPC, `GET /mcp` opens the SSE
  # notification stream. The Anubis plug negotiates both verbs itself.
  scope "/mcp" do
    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Seshat.MCP.Server
  end
end
