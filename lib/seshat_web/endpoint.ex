defmodule SeshatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :seshat

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug SeshatWeb.Router
end
