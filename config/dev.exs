import Config

config :gmaps_ex, GmapsEx.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "gmaps_ex_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :logger, level: :info
