# GmapsEx — Usage Guide

End-to-end how-to for the pure-Elixir Google Maps scraper.

---

## 1. Install

```bash
git clone <repo>
cd gmaps_ex
mix deps.get
mix ecto.setup            # creates DB + runs migrations (Postgres required)
```

Requires: Elixir 1.18+ / OTP 27+, PostgreSQL 14+.

---

## 2. One-shot from IEx (no DB needed)

```elixir
iex> Application.ensure_all_started(:gmaps_ex)
iex> {:ok, places} = GmapsEx.search("coffee shops", lat: 37.7749, lon: -122.4194, zoom: 13)
{:ok, [%GmapsEx.Place{title: "Blue Bottle Coffee", ...}, ...]}

iex> {:ok, full} = GmapsEx.place("0x80858098babc2d4b:0xbeedd659cc698c92", gl: "us")
{:ok, %GmapsEx.Place{title: "Blue Bottle Coffee", review_count: 682, ...}}
```

`search/2` is the basic XHR; `place/2` is the full per-place enrichment (two HTTP calls).

---

## 3. Full pipeline via CLI

```bash
# Single query × geo
mix gmaps.scrape --query "coffee shops" --geo "37.7749,-122.4194" --zoom 13

# Grid mode — splits a bbox into cells, one search per cell × keyword
mix gmaps.scrape \
  --query "restaurants" \
  --grid-bbox "37.7,-122.5,37.85,-122.35" \
  --grid-cell-km 1.5 \
  --zoom 13
```

What happens behind the scenes:

1. Search jobs go onto the Oban `:search` queue (4 parallel).
2. Each search hits Google's XHR endpoint and upserts ~20 basic-fields places.
3. Each place spawns a `:place` enrichment job (10 parallel).
4. Enrichment fetches full detail (review_count, address, website, hours, owner, about, photos) via two-step HTTP — no browser.

---

## 4. Worldwide queries (not just US)

Pass `--gl` for country code and `--lang` for language. Google's IP geolocation
will otherwise route you to your VPS's region.

```bash
# Paris cafés in French
mix gmaps.scrape --query "café" --geo "48.8566,2.3522" --zoom 14 --lang fr --gl fr

# Tokyo restaurants in Japanese
mix gmaps.scrape --query "レストラン" --geo "35.6762,139.6503" --zoom 14 --lang ja --gl jp

# Cairo coffee shops in Arabic
mix gmaps.scrape --query "قهوة" --geo "30.0444,31.2357" --zoom 13 --lang ar --gl eg

# São Paulo restaurants, Brazilian Portuguese
mix gmaps.scrape --query "restaurantes" --geo "-23.5505,-46.6333" --zoom 13 --lang pt --gl br
```

`gl` accepts any ISO 3166-1 alpha-2 country code Google supports (`us`, `gb`, `de`, `fr`, `jp`, `cn`, `br`, `mx`, `in`, `eg`, ...).

---

## 5. Export

After (or during) a scrape:

```bash
# CSV  — column set matches the Go scraper's Entry.CsvHeaders
mix gmaps.export --csv places.csv

# JSONL — one place per line, full struct
mix gmaps.export --jsonl places.jsonl

# Both at once
mix gmaps.export --csv places.csv --jsonl places.jsonl

# Filter with SQL fragment
mix gmaps.export --csv top.csv --where "review_rating >= 4.5 AND review_count >= 100"

# Upload to S3 (requires runtime config — see config/runtime.exs)
mix gmaps.export --s3 --s3-key snapshots/$(date +%Y-%m-%d).jsonl
```

---

## 6. Proxies

GmapsEx integrates with Webshare residential proxies. Configure via env:

```bash
# Webshare native format (host:port:user:pass), comma-separated
export GMAPS_PROXIES="proxy1.webshare.io:8080:user-1:pass1,proxy2.webshare.io:8080:user-2:pass2"

# Or URL format
export GMAPS_PROXIES="http://user:pass@proxy1.webshare.io:8080,http://user:pass@proxy2.webshare.io:8080"

mix gmaps.scrape --query "..." --geo "..."
```

The `ProxyPool` rotates round-robin. Proxies that return 5xx / time out get
marked dead for 5 minutes before being retried. Per-proxy rate limiter
(`Hammer`) caps at 1 req/sec — adjust via
`config :gmaps_ex, GmapsEx.Http.RateLimiter, per_proxy_per_second: N`.

---

## 7. Live progress via PubSub

The pipeline broadcasts events to a `Phoenix.PubSub` topic. Subscribe from any process:

```elixir
Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")

receive do
  {:places_found, query, n} -> IO.puts("#{query}: #{n} new places")
  {:place_enriched, title, count, rating} -> IO.puts("#{title} #{rating}* (#{count} reviews)")
  {:search_error, query, reason} -> IO.puts("FAIL #{query}: #{inspect(reason)}")
end
```

This is how a future LiveView dashboard would receive updates without polling
the DB. The PubSub server is started automatically in `application.ex`.

### Hooking a LiveView dashboard (optional)

`GmapsEx` itself ships no Phoenix dependency to keep the core lean. To add a
dashboard:

1. Create a separate Phoenix app in an umbrella, or add Phoenix + LiveView to
   this project's `mix.exs`.
2. From your LiveView's `mount/3`, call
   `Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")`.
3. Handle the same messages above in `handle_info/2`, push to socket assigns.
4. Use `Oban.Web` (paid) or query `oban_jobs` directly to show queue depth.

A 30-line LiveView is enough.

---

## 8. End-to-end workflow recap

```
┌────────────────────────────────────────────────────────┐
│ mix gmaps.scrape --query "..." --geo "lat,lon" --zoom  │
└────────────────────────────────────────────────────────┘
                       │
                       ▼ Runner.start
              ┌─────────────────┐
              │   Oban :search  │ ── concurrency 4
              └───────┬─────────┘
                      │ SearchWorker.perform
                      ▼
            GmapsEx.search/2 (one HTTP call, pb= param)
                      │
                      ▼ Parser.Search
              ~20 partial Places
                      │
                      ▼ Places.upsert (on conflict: data_id)
              ┌─────────────────┐
              │   Postgres      │ ◄────── partial places written
              └─────────────────┘
                      │
                      ▼ enqueue
              ┌─────────────────┐
              │   Oban :place   │ ── concurrency 10
              └───────┬─────────┘
                      │ PlaceWorker.perform
                      ▼
              GmapsEx.place/2 (two HTTP calls)
              ├─ GET /maps/place/?ftid=DATA_ID  → HTML
              └─ extract preload preview URL → GET /maps/preview/place?pb=...
                      │
                      ▼ Parser.Place
              Full Place struct (~30 fields)
                      │
                      ▼ Places.upsert
              Same DB row, fully populated
                      │
                      ▼ Exiter.incr_places_completed
              {:run_complete} broadcast when seeds_done == seeds_total
                            AND places_done == places_found
```

---

## 9. Validating a run

```sql
-- Quick health check
SELECT COUNT(*) AS total, COUNT(*) FILTER (WHERE review_count > 0) AS enriched FROM places;

-- Oban state
SELECT worker, state, COUNT(*) FROM oban_jobs GROUP BY 1, 2;

-- Sample
SELECT title, review_rating, review_count, phone, address
FROM places ORDER BY review_count DESC LIMIT 20;
```

A healthy scrape ends with:

- `total = enriched` (or close — some places will fail enrichment, see section 11)
- Oban: only `completed` rows
- No `retryable` lingering longer than 5 minutes (max backoff)

---

## 10. Stopping a run

Oban jobs are persistent. If you Ctrl-C the BEAM, jobs resume on next start.
To cancel pending work:

```sql
UPDATE oban_jobs SET state = 'cancelled', cancelled_at = now()
WHERE state IN ('available', 'scheduled', 'retryable');
```

Or in IEx:

```elixir
Oban.cancel_all_jobs(Oban.Job |> Ecto.Query.where([j], j.state in ["available", "scheduled", "retryable"]))
```

---

## 11. Anti-ban / anti-detection

Built-in by default:

- `CONSENT=YES+` cookie pre-set on every request — skips Google's EU consent interstitial.
- User-Agent rotated per request from 6 Firefox+Chrome desktop strings.
- `sec-fetch-*` headers added to mimic a real browser navigation.
- Exponential backoff with jitter on 429 / 5xx (500–2,500ms base × 2^N + 0–1,000ms jitter).
- Proxy ejection on 429 — pool rotates to a new IP.
- Per-proxy rate limit (default 1 req/sec).

What's NOT built-in:

- TLS fingerprint spoofing (JA3/JA4). If Google starts checking, you'd need
  something like [tls_client](https://github.com/bogdanfinn/tls-client) over a
  Port — out of scope for v1.
- CAPTCHA solving. If you hit one, the affected proxy is marked dead and
  retries route through a different IP.

---

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Search returns 0 places | Google response shape changed | Run `mix run --no-start -e 'IO.inspect(GmapsEx.search(...))'` and compare to old responses; the `pb=` template in `lib/gmaps_ex/pb_builder.ex` may need updating |
| `:place_json_not_found` for every URL | `pb=` template in preview link parsing changed | Inspect HTML manually; `lib/gmaps_ex/parser/html_extractor.ex` does the extraction |
| `Jason.DecodeError` from a search | Server returned compressed body but `decode_body: false` was set | Make sure no `accept-encoding` header is sent (default is fine) |
| `:preview_url_not_found` for some places | Google didn't include the preload link (~10–30% rate depending on locale) | These get cancelled cleanly. They can be re-attempted by running the scrape again — search will requeue them |
| `429` rate limited | Single-IP scraping at too high a rate | Configure proxies via `GMAPS_PROXIES`; the pool will rotate |
| Oban jobs stuck `retryable` | Worker is hitting an unrecoverable exception | `SELECT errors FROM oban_jobs WHERE state = 'retryable' LIMIT 1;` to see the stack |
| `too many clients already` from Postgres | Multiple BEAM instances running | `pkill -f "mix run"`, then verify with `SELECT count(*) FROM pg_stat_activity` |

---

## 13. Tests

```bash
# Unit tests (no live HTTP)
GMAPS_NO_DB=1 mix test --no-start

# Recompile cleanly if something seems stale
rm -rf _build/dev/lib/gmaps_ex && mix compile
```
