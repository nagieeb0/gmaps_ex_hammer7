import Config

config :gmaps_ex, GmapsEx.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "gmaps_ex_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :gmaps_ex, Oban, testing: :manual

config :logger, level: :warning
