# Embedding GmapsEx in Your Phoenix / Elixir App

GmapsEx is designed to be embedded — that's its core value vs. running the Go scraper as a separate service. This guide walks through adding it to an existing app cleanly.

---

## 1. Add the dependency

In your host app's `mix.exs`:

```elixir
defp deps do
  [
    # ... your existing deps ...
    {:gmaps_ex, github: "your-org/gmaps_ex", branch: "main"},
    # If you're not already using these, GmapsEx requires them:
    {:ecto_sql, "~> 3.12"},
    {:postgrex, "~> 0.19"},
    {:oban, "~> 2.18"},
    {:phoenix_pubsub, "~> 2.1"}
  ]
end
```

```bash
mix deps.get
```

---

## 2. Decide: same DB or its own?

### Option A — Reuse your host app's database (recommended for SaaS)

The `places`, `reviews`, and `oban_jobs` tables live alongside your own. One Postgres, one Repo. Cheapest.

In your host app's repo config:

```elixir
# config/config.exs
config :gmaps_ex, ecto_repos: [MyApp.Repo]
config :gmaps_ex, GmapsEx.Repo, repo: MyApp.Repo  # alias to your repo
```

Copy GmapsEx's migrations into your host app's migrations directory:

```bash
cp deps/gmaps_ex/priv/repo/migrations/*.exs priv/repo/migrations/
mix ecto.migrate
```

You **don't** start `GmapsEx.Repo` in your supervision tree — it points to yours.

### Option B — Separate database

Keep `gmaps_ex_*` tables isolated. Useful if scraped data has different retention or compliance rules.

```elixir
# config/dev.exs
config :gmaps_ex, GmapsEx.Repo,
  database: "gmaps_ex_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost"
```

You DO start `GmapsEx.Repo` separately. The default supervision tree handles this — just don't disable it.

---

## 3. Supervision tree — GmapsEx self-supervises

**Important**: `gmaps_ex` is an OTP application with its own `start/2` callback,
so it auto-starts its own supervision tree (Repo, Oban, `GmapsEx.PubSub`,
ProxyPool, SessionStore, Dedupe, Exiter) the moment your host app boots and
loads the dependency.

You do **NOT** need to add those children to your `lib/my_app/application.ex`.
Doing so will fail with `already started: #PID<...>`.

Your `application.ex` keeps only what your app owns:

```elixir
def start(_type, _args) do
  children = [
    MyApp.Repo,                              # your own Repo
    {Phoenix.PubSub, name: MyApp.PubSub},    # your own PubSub
    MyAppWeb.Endpoint
    # — no GmapsEx children here —
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

To **subscribe** to GmapsEx events from your LiveView or process, use the
auto-started `GmapsEx.PubSub`:

```elixir
Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")
```

### Sharing your DB / Oban (advanced)

If you'd rather have GmapsEx write into your existing Repo and Oban instead
of its own, set the env var `GMAPS_NO_DB=1` before BEAM starts. That causes
GmapsEx to skip its Repo + Oban children. You then become responsible for
including both — config them under `:gmaps_ex, GmapsEx.Repo` and
`:gmaps_ex, Oban` so the workers find them.

This is the route to take if you want one Postgres, not two.

---

## 4. Configure Oban — merge with your existing queues

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [
    # your existing queues
    mailers: 10,
    default: 20,

    # GmapsEx queues — tune to your proxy capacity
    search: 4,
    place: 10,
    reviews: 6,
    emails: 5
  ],
  plugins: [Oban.Plugins.Pruner, Oban.Plugins.Lifeline]
```

Then override the `:gmaps_ex, Oban` config to point at your Oban instance:

```elixir
config :gmaps_ex, Oban,
  repo: MyApp.Repo,
  queues: [search: 4, place: 10, reviews: 6, emails: 5],
  plugins: [Oban.Plugins.Pruner, Oban.Plugins.Lifeline]
```

Or simpler — don't start a second Oban. Skip the `{Oban, ...}` line in your supervision tree from §3 and the workers (`GmapsEx.Workers.SearchWorker`, etc.) will use your host app's Oban.

---

## 5. Use it from your code

### From a Phoenix controller / context

```elixir
defmodule MyApp.CompetitorAgent do
  alias GmapsEx.{Place, Repo, Runner}

  @doc "Pull fresh competitor data for a given metro + keyword"
  def refresh_competitors(keyword, %{lat: lat, lon: lon, country: gl}) do
    {:ok, _n_jobs} = Runner.start([%{
      query: keyword,
      lat: lat,
      lon: lon,
      zoom: 13,
      gl: gl
    }])
  end

  @doc "Get cached competitor data for SWOT enrichment"
  def competitors(keyword, lat, lon, radius_km \\ 5) do
    import Ecto.Query

    Place
    |> where([p], fragment("? % ?", p.category, ^keyword))
    |> where([p],
      fragment(
        "earth_distance(ll_to_earth(?, ?), ll_to_earth(?, ?))",
        p.latitude, p.longitude, ^lat, ^lon
      ) < ^(radius_km * 1000)
    )
    |> order_by([p], desc: p.review_count)
    |> Repo.all()
  end
end
```

### From a LiveView (real-time progress)

```elixir
defmodule MyAppWeb.ScrapeLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")
    end

    {:ok,
     assign(socket,
       places: [],
       progress: %{found: 0, enriched: 0, with_reviews: 0}
     )}
  end

  def handle_event("scrape", %{"query" => q, "lat" => lat, "lon" => lon}, socket) do
    GmapsEx.Runner.start([%{
      query: q,
      lat: String.to_float(lat),
      lon: String.to_float(lon),
      zoom: 13
    }])

    {:noreply, put_flash(socket, :info, "Scrape started")}
  end

  def handle_info({:places_found, _query, n}, socket) do
    {:noreply, update(socket, :progress, &Map.update!(&1, :found, fn x -> x + n end))}
  end

  def handle_info({:place_enriched, title, count, rating, _inline_reviews}, socket) do
    place = %{title: title, rating: rating, reviews: count}
    {:noreply,
     socket
     |> update(:places, &[place | &1])
     |> update(:progress, &Map.update!(&1, :enriched, fn x -> x + 1 end))}
  end

  def handle_info(_), do: {:noreply, socket}
end
```

### From an Oban-backed agent / cron

```elixir
defmodule MyApp.Workers.NightlyCompetitorRefresh do
  use Oban.Worker, queue: :default

  @impl true
  def perform(_) do
    # Refresh competitor data for all the metros our customers operate in
    Repo.all(MyApp.CustomerMetros)
    |> Enum.map(fn metro ->
      %{
        query: "competitors of #{metro.business_type}",
        lat: metro.lat,
        lon: metro.lon,
        zoom: 13,
        gl: metro.country_code
      }
    end)
    |> GmapsEx.Runner.start()
  end
end
```

Schedule it with `Oban.Plugins.Cron`:

```elixir
config :my_app, Oban,
  plugins: [
    {Oban.Plugins.Cron, crontab: [
      {"0 3 * * *", MyApp.Workers.NightlyCompetitorRefresh}
    ]}
  ]
```

---

## 6. Access the scraped data

GmapsEx is just Ecto schemas under the hood — query them directly:

```elixir
alias GmapsEx.{Place, Review, Repo}
import Ecto.Query

# All places with their inline reviews preloaded
Place
|> preload(:reviews)  # if you add `has_many :reviews, Review` to Place
|> where([p], p.review_rating >= 4.5)
|> Repo.all()

# Average rating per category in a city
Place
|> where([p],
  fragment("earth_box(ll_to_earth(?, ?), ?) @> ll_to_earth(?, ?)", ^lat, ^lon, ^radius_m, p.latitude, p.longitude)
)
|> group_by([p], p.category)
|> select([p], {p.category, avg(p.review_rating), count(p.id)})
|> Repo.all()

# All reviews for a competitor (for SWOT mining)
Review
|> join(:inner, [r], p in Place, on: r.place_id == p.id)
|> where([_r, p], p.cid == ^competitor_cid)
|> Repo.all()
```

To add the `has_many` association, override `Place` in your app or send a PR — neither schema currently declares the relationship.

---

## 7. Tune for your scale

```elixir
# config/runtime.exs (production)

# Bump the Oban concurrency to match your proxy capacity
config :my_app, Oban,
  queues: [
    search: String.to_integer(System.get_env("GMAPS_SEARCH_CONCURRENCY") || "20"),
    place: String.to_integer(System.get_env("GMAPS_PLACE_CONCURRENCY") || "100"),
    reviews: String.to_integer(System.get_env("GMAPS_REVIEWS_CONCURRENCY") || "10"),
    emails: String.to_integer(System.get_env("GMAPS_EMAILS_CONCURRENCY") || "10")
  ]

# Proxy pool
config :gmaps_ex, GmapsEx.Http.ProxyPool,
  proxies: (System.get_env("GMAPS_PROXIES") || "") |> String.split(",", trim: true)

# Per-proxy rate limit
config :gmaps_ex, GmapsEx.Http.RateLimiter,
  per_proxy_per_second: String.to_integer(System.get_env("GMAPS_RPS") || "1")
```

---

## 8. Testing your integration

In your test config, set Oban to manual mode (no background workers):

```elixir
# config/test.exs
config :my_app, Oban, testing: :manual
```

Then in tests:

```elixir
use Oban.Testing, repo: MyApp.Repo

test "scrape enqueues a search job" do
  MyApp.CompetitorAgent.refresh_competitors("dentists",
    %{lat: 51.5, lon: -0.12, country: "gb"})

  assert_enqueued(
    worker: GmapsEx.Workers.SearchWorker,
    args: %{"query" => "dentists", "gl" => "gb"}
  )
end

test "place worker upserts to DB" do
  # Stub the HTTP layer or use a captured fixture
  {:ok, _job} = perform_job(GmapsEx.Workers.PlaceWorker, %{
    "data_id" => "0xtest:0xfixture",
    "lang" => "en",
    "gl" => "us"
  })

  assert Repo.aggregate(GmapsEx.Place, :count) >= 1
end
```

---

## 9. What you don't get for free

- **No Web UI / admin dashboard** — you build it (a LiveView subscribed to PubSub gives you 80%).
- **No REST API** — if you need one for non-Elixir clients, add a Phoenix controller wrapping `GmapsEx.Runner.start/1` and `GmapsEx.Places.upsert/1`.
- **No multi-tenant scoping** — places aren't tagged by tenant. If you need that, add a `tenant_id` column to `places` and pass it through `Runner.start/1` via job args. ~30 LOC.
- **No full review pagination yet** — see [COMPARISON.md §5](COMPARISON.md) for the honest disclosure. Inline ~10 reviews per place are persisted automatically.

---

## 10. Minimal embedding cheat sheet

```elixir
# mix.exs
{:gmaps_ex, github: "your-org/gmaps_ex"}

# config/config.exs
config :gmaps_ex, GmapsEx.Repo, repo: MyApp.Repo
config :gmaps_ex, Oban, repo: MyApp.Repo, queues: [search: 4, place: 10, reviews: 6, emails: 5]

# application.ex children
{Phoenix.PubSub, name: GmapsEx.PubSub},
GmapsEx.Http.ProxyPool, GmapsEx.Http.SessionStore, GmapsEx.Dedupe, GmapsEx.Exiter

# Anywhere in your code
GmapsEx.search("query", lat: ..., lon: ..., zoom: 13, gl: "us")
GmapsEx.Runner.start([%{query: ..., lat: ..., lon: ..., zoom: 13}])
Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")
```

That's it.
