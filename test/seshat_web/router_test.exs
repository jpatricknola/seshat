defmodule SeshatWeb.RouterTest do
  use ExUnit.Case, async: true

  test "exposes only the MCP endpoint and its discovery fallback" do
    routes = Phoenix.Router.routes(SeshatWeb.Router)

    assert Enum.map(routes, &{&1.verb, &1.path, &1.plug}) == [
             {:*, "/.well-known/*path", SeshatWeb.Plugs.NoAuthDiscovery},
             {:*, "/mcp", Anubis.Server.Transport.StreamableHTTP.Plug}
           ]
  end
end
