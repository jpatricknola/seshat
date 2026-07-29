defmodule SeshatWeb.Plugs.NoAuthDiscovery do
  @moduledoc """
  Answers OAuth discovery probes with a quiet 404.

  MCP clients look for authorization-server metadata (RFC 8414) and
  protected-resource metadata (RFC 9728) under `/.well-known/` before deciding
  whether they need a token. Seshat has no authorization — it binds localhost
  and the only thing behind it is your own copy of Ableton — so the honest
  answer is "no such metadata", and the client then connects anonymously.

  404 is what that answer looks like on the wire, so this plug changes no
  behaviour. What it changes is that an expected, once-per-connection probe
  stops raising `Phoenix.Router.NoRouteError`, which in dev prints a full stack
  trace and reads like a fault.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> send_resp(404, "")
    |> halt()
  end
end
