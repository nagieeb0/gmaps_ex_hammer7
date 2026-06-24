# GmapsEx

[![Hex.pm](https://img.shields.io/hexpm/v/gmaps_ex.svg)](https://hex.pm/packages/gmaps_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/gmaps_ex)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Pure-Elixir Google Maps scraper. No browser. Embed it as a library in your Phoenix or Elixir app.**

```elixir
{:ok, places} = GmapsEx.search("coffee shops", lat: 37.7749, lon: -122.4194, zoom: 13)
# → [%GmapsEx.Place{title: "Blue Bottle Coffee", review_rating: 4.6, review_count: 682, ...}, ...]
```

GmapsEx surfaces ~30 fields per place — title, rating, review count, hours, phone, website, owner-claimed status, photos, address breakdown, reservations link, menu link, popular times — via direct XHR calls to Google's `pb=` endpoints. No Chromium, no Playwright, no Node.js. ~10× lower RAM than browser-based scrapers; same data.

## When to use

- ✅ You're building an Elixir/Phoenix app that needs Google Maps business data (CRM, agent, SWOT tool, lead-gen)
- ✅ You want the data layer as a library, not a separate Docker service
- ✅ You want Postgres + Oban + PubSub-native integration
- ❌ You want a turnkey CLI binary with a Web UI and SaaS edition (use the [Go scraper](https://github.com/gosom/google-maps-scraper) instead)

See [`COMPARISON.md`](COMPARISON.md) for the head-to-head.

---

## Install

```elixir
# mix.exs
def deps do
  [
    {:gmaps_ex, "~> 0.1"}
  ]
end
```

```bash
mix deps.get
mix ecto.setup       # Postgres required — see config/dev.exs
```

## Quick start (5 lines)

```elixir
# Application boot — gmaps_ex auto-supervises itself. Just have your DB ready.

iex> Application.ensure_all_started(:gmaps_ex)
iex> {:ok, places} = GmapsEx.search("dentists", lat: 51.5074, lon: -0.1278, zoom: 14, gl: "gb")
iex> Enum.map(places, & &1.title)
["Dr Smith Dental Practice", "Harley Street Dental", "Central London Dental", ...]
```

## CLI

```bash
# Multiple queries × one location, dump CSV
mix gmaps.scrape \
  --query "مقاهي" --query "كافيهات" --query "مطاعم" \
  --geo "30.7834,30.9983" --zoom 14 --lang ar --gl eg \
  --csv tanta.csv

# Grid mode — scan a bbox, run per cell
mix gmaps.scrape \
  --query "coffee shops" \
  --grid-bbox "37.7,-122.5,37.85,-122.35" --grid-cell-km 1.5 \
  --json sf-coffee.json --search-concurrency 10 --place-concurrency 20

# Input file with one query per line
mix gmaps.scrape --input queries.txt --geo "30.78,30.99" --gl eg --csv out.csv
```

All flags: see [`USAGE.md`](USAGE.md).

## What you get per place

```elixir
%GmapsEx.Place{
  data_id: "0x80858098babc2d4b:0xbeedd659cc698c92",
  cid: "13757888117856636050",
  place_id: "ChIJSyy8uphggIARkoxpzFnW7b4",
  title: "Blue Bottle Coffee",
  category: "Coffee shop",
  categories: ["Coffee shop", "Cafe"],
  address: "315 Linden St, San Francisco, CA 94102",
  latitude: 37.7766,
  longitude: -122.4232,
  phone: "(510) 661-3510",
  website: "https://bluebottlecoffee.com/...",
  review_rating: 4.6,
  review_count: 682,
  open_hours: %{"Monday" => ["7 AM – 6 PM"], ...},
  reviews_per_rating: %{"1" => 8, "2" => 12, "3" => 47, "4" => 178, "5" => 437},
  status: "Open",
  timezone: "America/Los_Angeles",
  price_range: "$$",
  reservations: [%{link: "...", source: "OpenTable"}],
  order_online: [%{link: "...", source: "DoorDash"}],
  about: [%{id: "service_options", name: "Service options", options: [...]}],
  images: [...],
  owner: %{id: "...", name: "Blue Bottle Coffee", link: "..."},
  complete_address: %{street: "315 Linden St", city: "San Francisco", ...},
  emails: ["press@bluebottlecoffee.com"]  # via opt-in EmailWorker
  # plus reviews via has_many :reviews
}
```

## Architecture

```
mix gmaps.scrape  ──┐
GmapsEx.search/2 ──┼─→  Oban queue: search ─→ search XHR ─→ ~20 Place results upserted
GmapsEx.Runner ────┘                                            │
                                                                ↓
                              Oban queue: place ─→ place-detail XHR ─→ full Place + inline reviews
                                                                              │
                                                                              ↓ (opt-in)
                                                              Oban queue: emails ─→ website crawl
                                                              Oban queue: reviews ─→ pluggable backend

PubSub broadcast on every step → your LiveView dashboard subscribes
```

Built on `Req` + `Jason` + `Floki` + `Ecto` + `Oban` + `Broadway` + `Phoenix.PubSub` + `Hammer` + `NimbleCSV`. All standard library deps you probably already have.

## Embed in your Phoenix app

```elixir
# That's it. The library auto-supervises Repo, Oban, PubSub, ProxyPool,
# SessionStore, Dedupe, Exiter when your app boots.

# In your code:
{:ok, places} = GmapsEx.search("competitors of bakeries", lat: ..., lon: ..., gl: "us")
GmapsEx.Runner.start([%{query: "...", lat: ..., lon: ..., zoom: 13, tenant_id: current_user.tenant_id}])
Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")
```

Full embedding guide: [`EMBEDDING.md`](EMBEDDING.md).

A complete LiveView demo lives in the `gmaps_dash/` sibling app in the repo — see the `WALKTHROUGH.md` there.

## Reviews

For every place you scrape, ~4–8 most recent reviews are extracted from the place-detail XHR and persisted to the `reviews` table automatically. Each review captures `name`, `rating`, `description` (text), `when` (date), `profile_picture`, `images`.

```elixir
place = Repo.get_by(GmapsEx.Place, data_id: "...") |> Repo.preload(:reviews)
Enum.map(place.reviews, & {&1.rating, &1.description})
# → [{5, "Best coffee in SF, hands down."}, {2, "Long wait, mediocre service."}, ...]
```

For **full pagination** (1,000+ reviews per place to match the Go scraper), Google requires browser-session cookies pure HTTP can't reliably get. We provide a pluggable `GmapsEx.Reviews.Backend` behaviour — implement it with Playwright (~150 LOC) and wire it via:

```elixir
config :gmaps_ex, GmapsEx.Workers.ReviewsWorker, backend: MyApp.PlaywrightReviewsBackend
```

Details in [`GAPS.md`](GAPS.md) and the `lib/gmaps_ex/reviews/backend.ex` module doc.

## Worldwide support

```bash
mix gmaps.scrape --query "café"  --geo "48.8566,2.3522"  --lang fr --gl fr  --csv paris.csv
mix gmaps.scrape --query "レストラン" --geo "35.6762,139.6503" --lang ja --gl jp --csv tokyo.csv
mix gmaps.scrape --query "مقاهي" --geo "30.7834,30.9983" --lang ar --gl eg --csv tanta.csv
```

`gl` is the ISO 3166 country code — set it explicitly or Google's IP-geolocation will override your viewport.

## Production at scale

For 1 M+ places: see [`PRODUCTION.md`](PRODUCTION.md). Concrete numbers — Hetzner CX22 (€4/mo) + Webshare Pro 100 ($30/mo) sustains ~5 M places/month single node.

## Documentation

- [USAGE.md](USAGE.md) — full CLI + IEx walkthrough
- [EMBEDDING.md](EMBEDDING.md) — drop into your Phoenix app
- [PRODUCTION.md](PRODUCTION.md) — capacity, proxies, anti-ban, monitoring
- [COMPARISON.md](COMPARISON.md) — vs. the Go scraper, honest numbers
- [GAPS.md](GAPS.md) — what we don't ship and how to add it
- [CHANGELOG.md](CHANGELOG.md)

## Tests

```bash
mix test          # 51 tests, all pass
mix credo --strict
mix dialyzer
mix precommit     # combines all of the above
```

## License

MIT. See `LICENSE` in the repository.

## Acknowledgements

This library reimplements the data-extraction patterns of [`gosom/google-maps-scraper`](https://github.com/gosom/google-maps-scraper) in pure Elixir. The `pb=` URL templates and parser index walks are directly ported from that project. Massive credit to its author and contributors — without it, this library wouldn't exist.
