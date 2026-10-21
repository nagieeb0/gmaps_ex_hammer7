import Config

config :gmaps_ex, GmapsEx.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "gmaps_ex_dev",
  show_sensitive_data_on_connection_error: true,
  # Sized for the scraper's Oban worker concurrency (search + place workers each
  # hit the DB). Keep this ≥ search_concurrency + place_concurrency + headroom.
  #
  # Overridable because two BEAM nodes against one Postgres (a running
  # phx.server plus a `mix run` batch job) ask for 2 × pool_size and blow past
  # the server's default max_connections of 100 — which surfaces as
  # `FATAL 53300 too_many_connections`, not as a pool error. Give the batch job
  # a smaller pool: POOL_SIZE=24 mix run script.exs
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "64")

config :logger, level: :info
