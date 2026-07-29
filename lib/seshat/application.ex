defmodule Seshat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    install_log_filter()

    # The catalog is deliberately independent of OSC: it answers from disk
    # with Ableton closed, and only needs Live running to reindex.
    children =
      [
        SeshatWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:seshat, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Seshat.PubSub}
      ] ++
        if Application.get_env(:seshat, :start_osc, true) do
          [Seshat.OSC.Transport, Seshat.Session.State]
        else
          []
        end ++
        if Application.get_env(:seshat, :start_catalog, true) do
          [Seshat.Library.Catalog]
        else
          []
        end ++
        if Application.get_env(:seshat, :start_mcp, true) do
          [mcp_supervisor_spec()]
        else
          []
        end ++
        [SeshatWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Seshat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SeshatWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # A client disconnecting is not a warning. See `Seshat.MCP.LogFilter` for why
  # this can't be done with `config :anubis_mcp, logging: [...]`.
  defp install_log_filter do
    :logger.add_primary_filter(
      :seshat_mcp_client_disconnect,
      {&Seshat.MCP.LogFilter.filter/2, []}
    )

    :ok
  end

  defp mcp_supervisor_spec do
    %{
      id: Seshat.MCP.Supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             %{
               id: Seshat.MCP.Server,
               start:
                 {Anubis.Server.Supervisor, :start_link,
                  [Seshat.MCP.Server, [transport: :streamable_http]]},
               type: :supervisor
             }
           ],
           [strategy: :one_for_one]
         ]},
      type: :supervisor,
      restart: :temporary
    }
  end
end
