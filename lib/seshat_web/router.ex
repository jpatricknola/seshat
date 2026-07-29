defmodule SeshatWeb.Router do
  use SeshatWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SeshatWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", SeshatWeb do
    pipe_through :browser

    live "/", AssistantLive
  end

  # Seshat has no OAuth. Clients probe for it anyway before falling back to an
  # unauthenticated connection, so answer explicitly rather than letting an
  # expected probe raise NoRouteError. See the plug's moduledoc.
  scope "/.well-known" do
    match :*, "/*path", SeshatWeb.Plugs.NoAuthDiscovery, []
  end

  # No `:accepts` pipeline here on purpose. Streamable HTTP serves two content
  # types on one path — `POST /mcp` carries JSON-RPC, `GET /mcp` opens the SSE
  # notification stream with `Accept: text/event-stream` — so `plug :accepts,
  # ["json"]` (which Anubis's own docstring suggests) 406s every stream open
  # before the plug runs. The plug negotiates both verbs itself.
  scope "/mcp" do
    forward "/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Seshat.MCP.Server
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:seshat, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SeshatWeb.Telemetry
    end
  end
end
