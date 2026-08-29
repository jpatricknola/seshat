# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# Configure the endpoint
config :seshat, SeshatWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SeshatWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Seshat.PubSub

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# --- Audio generation ---
#
# `generate_audio` renders through `Seshat.Generation.StableAudio`, which drives
# the locally installed Stable Audio 3 MLX runtime. Every value below has a
# default in that module, so an ordinary installation configures nothing; they
# are listed here because they are the whole configuration surface of the
# feature.
#
#   :generation_backend        the module implementing Seshat.Generation.Backend
#                              (compile-time — config/test.exs points it at the
#                              fake so the suite never starts a subprocess)
#   :generation_executable     the `sa3` wrapper
#                              (~/.seshat/stable-audio-3/optimized/mlx/sa3)
#   :generation_model_root     the runtime checkout holding scripts/, .venv/ and
#                              models/ (~/.seshat/stable-audio-3/optimized/mlx)
#   :generation_timeout        how long one render may take, ms (60_000)
#   :generation_max_output_bytes  retained runtime output for diagnostics (32KB)
#   :generated_root            where takes are written (~/.seshat/generated)
#
# `:generated_root` is **not** an installation preference: it must equal
# `path_safety.IMPORT_ROOT` in the AbletonOSC fork, which is what the import
# address resolves the basename Seshat sends underneath. It exists so the test
# suite can point at a tmp directory. Moving it for real means moving the fork
# constant in the same change, and `vendored_addresses_test` pins the literal.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
