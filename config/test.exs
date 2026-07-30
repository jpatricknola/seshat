import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :seshat, SeshatWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "6D3RBjYq7zqokqpStH4u5MpTkluqGuxhJzJriQiFUG+SS8hgEfCuAlR8s91Axce3",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Don't start OSC transport, session state, MCP server, or the library catalog
# in tests — catalog tests start their own with an isolated table and path.
config :seshat, :start_osc, false
config :seshat, :start_mcp, false
config :seshat, :start_catalog, false

# The suite must be safe to run with Live open and unsaved work. AbletonOSC
# listens on 11000 and replies to a fixed 11001; these are deliberately neither.
# Any test that starts Seshat.OSC.Transport therefore talks to a test-local
# socket (Seshat.Test.OSCSink) and cannot reach Ableton — asserted by
# test/seshat/osc/transport_test.exs.
config :seshat, :osc_send_port, 31000
config :seshat, :osc_reply_port, 31001

# Stub Anthropic API calls in tests
config :seshat, :anthropic_api_key, "test-key"
config :seshat, :agent_req_options, plug: {Req.Test, Seshat.Agent}
