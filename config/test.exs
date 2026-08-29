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

# Don't start OSC transport, session state, MCP server, or the library catalog
# in tests — catalog tests start their own with an isolated table and path.
config :seshat, :start_osc, false
config :seshat, :start_mcp, false
config :seshat, :start_catalog, false

# The suite must be safe to run with Live open and unsaved work. AbletonOSC
# listens on 11000 and replies to a fixed 11001; these are deliberately neither.
# Tests inject OS-assigned ephemeral ports from Seshat.Test.OSCSink into each
# Transport they start. Zero is the safe fallback: an uninjected Transport can
# bind locally but cannot send to AbletonOSC's 11000, and concurrent test BEAMs
# cannot collide on a process-wide fixed port. Asserted by
# test/seshat/osc/transport_test.exs.
config :seshat, :osc_send_port, 0
config :seshat, :osc_reply_port, 0

# Audio generation never starts a subprocess in the suite: the backend module is
# a compile-time choice (see Seshat.Generation.Backend), so this points the whole
# `Seshat.Generation.AudioClip` workflow at a scripted fake. The one place the
# real adapter is exercised is its own test file, which drives a throwaway
# executable it writes itself.
config :seshat, :generation_backend, Seshat.Test.FakeGenerationBackend
