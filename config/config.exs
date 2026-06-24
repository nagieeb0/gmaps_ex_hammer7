import Config

config :gmaps_ex,
  ecto_repos: [GmapsEx.Repo]

config :gmaps_ex, GmapsEx.Repo, migration_primary_key: [type: :binary_id]

config :gmaps_ex, Oban,
  repo: GmapsEx.Repo,
  queues: [search: 4, place: 10, reviews: 6, emails: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    Oban.Plugins.Lifeline
  ]

config :gmaps_ex, GmapsEx.Http.Client,
  default_lang: "en",
  request_timeout_ms: 30_000,
  max_retries: 3,
  user_agents: [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.4; rv:128.0) Gecko/20100101 Firefox/128.0",
    "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  ]

config :gmaps_ex, GmapsEx.Http.RateLimiter, per_proxy_per_second: 1

config :gmaps_ex, GmapsEx.Http.ProxyPool, proxies: []

import_config "#{config_env()}.exs"
