import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing"

  config :gmaps_ex, GmapsEx.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  proxies =
    case System.get_env("GMAPS_PROXIES") do
      nil -> []
      "" -> []
      str -> String.split(str, ",", trim: true)
    end

  config :gmaps_ex, GmapsEx.Http.ProxyPool, proxies: proxies

  if bucket = System.get_env("S3_BUCKET") do
    config :gmaps_ex, GmapsEx.Output.S3,
      bucket: bucket,
      prefix: System.get_env("S3_PREFIX") || "gmaps_ex"

    config :ex_aws,
      access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
      secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
      region: System.get_env("AWS_REGION") || "us-east-1"
  end
end
