defmodule Seshat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SeshatWeb.Telemetry,
        Seshat.Repo,
        {DNSCluster, query: Application.get_env(:seshat, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Seshat.PubSub}
      ] ++
        if Application.get_env(:seshat, :start_osc, true) do
          [Seshat.OSC.Transport, Seshat.Session.State]
        else
          []
        end ++
        if Application.get_env(:seshat, :start_mcp, true) do
          [Hermes.Server.Registry, mcp_supervisor_spec()]
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

  defp mcp_supervisor_spec do
    %{
      id: Seshat.MCP.Supervisor,
      start: {Supervisor, :start_link, [
        [
          %{
            id: Seshat.MCP.Server,
            start: {Hermes.Server.Supervisor, :start_link, [Seshat.MCP.Server, [transport: :streamable_http]]},
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
