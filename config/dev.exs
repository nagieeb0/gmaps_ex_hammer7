import Config

config :gmaps_ex, GmapsEx.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 55432,
  database: System.get_env("GMAPS_DB") || "gmaps_ex_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, level: :info
