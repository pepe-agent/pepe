defmodule Pepe.Repo do
  use Ecto.Repo,
    otp_app: :pepe,
    adapter: Ecto.Adapters.Postgres
end
