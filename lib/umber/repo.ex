defmodule Umber.Repo do
  use Ecto.Repo,
    otp_app: :umber,
    adapter: Ecto.Adapters.Postgres
end
