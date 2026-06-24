defmodule GmapsEx.Repo do
  use Ecto.Repo,
    otp_app: :gmaps_ex,
    adapter: Ecto.Adapters.Postgres
end
