defmodule Seshat.Repo do
  use Ecto.Repo,
    otp_app: :seshat,
    adapter: Ecto.Adapters.Postgres
end
