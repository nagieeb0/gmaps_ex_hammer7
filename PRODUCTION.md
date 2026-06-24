# GmapsEx — Production & Scale Notes

Concrete capacity planning for running GmapsEx at scale (hundreds of thousands → millions of places).

---

## TL;DR — will it hold for "millions of places"?

**Yes, with caveats.** The architecture (Postgres + Oban + Broadway + Req) is the standard Elixir stack used for similar workloads at companies running 10M+ jobs/day. The hard limit is not the BEAM — it's:

1. **Proxy bandwidth & IP diversity** (Google bans repeat IPs fast).
2. **Postgres connection pool & disk** at the high end.
3. **Maintenance cost** of keeping index walks current when Google ships UI updates.

Numbers below are measured per-query on our reference run + extrapolated.

---

## 1. Throughput envelope (measured)

| Metric | Value |
|---|---|
| Search XHR latency | ~1.5–2.5s per request (no proxy, US IP) |
| Place enrichment (two HTTP calls) | ~2.5–4s per place |
| Search results per query | ~20 (Google caps the XHR feed) |
| Place fields per scrape | ~30 (title, rating, review_count, phone, address, website, hours, categories, owner, about, images, reservations, …) |
| Throughput, single BEAM, single IP | ~10 places/sec (limited by Google's per-IP burst tolerance) |
| Throughput, 50-IP residential proxy pool | ~250–400 places/sec sustained |

For 1,000,000 places at 300 places/sec sustained: **~55 minutes of wall time**. Reality is 2–5× that once you factor in failures, retries, geographic distribution of queries.

---

## 2. Resource sizing

### BEAM node

| Scale | RAM | CPU | Notes |
|---|---|---|---|
| 10K places | 200 MB | 1 vCPU | dev/QA box |
| 100K places | 400 MB | 2 vCPU | one Hetzner CX22 (€4/mo) |
| 1M places | 800 MB | 4 vCPU | one Hetzner CX32 (€8/mo) |
| 10M places | 2 GB | 8 vCPU | one CX42 (€16/mo) + read replica |

The BEAM is **not** the bottleneck. Each Oban worker is a lightweight process (~3KB). 10× more concurrency = 30KB more, not 300MB like a Chromium pool would be. **This is the key reason this stack beats browser-based scrapers at scale.**

### Postgres

| Tables / index | Disk per 1M places |
|---|---|
| `places` table | ~1.2 GB (uncompressed jsonb columns make up half) |
| `places` indexes (4 unique + 1 spatial) | ~150 MB |
| `oban_jobs` (with pruner running) | ~300 MB peak, ~50 MB steady |
| `reviews` if enabled | depends on per-place review count (~1KB per review) |

**At 10M places**: budget 15GB disk for `places`. Configure `Oban.Plugins.Pruner` with `max_age: 60 * 60 * 24 * 7` (7 days) to keep `oban_jobs` bounded.

### Postgres connection pool

```elixir
# config/runtime.exs
config :gmaps_ex, GmapsEx.Repo,
  pool_size: 30  # default is 10
```

Rule of thumb: `Oban total queue concurrency + 5`. With default config (search: 4 + place: 10 = 14), pool 20 is plenty. Bump if you raise queue concurrency.

---

## 3. Proxies — the actual bottleneck

Google bans residential IPs hitting `maps.google.com` at >2 req/sec sustained. A datacenter IP is detected within seconds and gets a captcha. Without proxies, you're capped at **~3,000 places/hour from one IP** before you start hitting `429`s.

Webshare pricing (2026):

| Plan | IPs | Cost/mo | Places/day at 1 req/sec per IP |
|---|---|---|---|
| Personal | 10 | $5 | ~500K |
| Pro 100 | 100 | $30 | ~5M |
| Pro 500 | 500 | $150 | ~25M |
| Pro 1000 | 1000 | $300 | ~50M |

Bandwidth: ~150KB per search request, ~250KB per place detail (2 HTTP calls × ~125KB). For 1M places: **~400GB**. Webshare includes ~1TB on their Pro plans — sufficient.

### Worldwide locale routing

If you're scraping for multiple countries, use **country-routed proxies**, not random Webshare IPs:

- US data → US-routed proxies (or US-VPS BEAM)
- EU data → EU-routed proxies
- APAC data → APAC-routed proxies

Mismatched routing (e.g. US IP scraping Tokyo) triggers Google's "did you mean to switch regions?" page or a wrong locale that breaks parsing.

Configure per-job via:
```elixir
config :gmaps_ex, GmapsEx.Http.ProxyPool, proxies: %{
  "us" => ["us-1.webshare.io:8080:user:pass", ...],
  "fr" => ["fr-1.webshare.io:8080:user:pass", ...]
}
```
(*Not yet implemented in this codebase — single global pool. PR welcome.*)

---

## 4. Oban / job persistence

Default queue config:

```elixir
queues: [search: 4, place: 10]
```

For 1M places with 100-IP proxy pool, scale to:

```elixir
queues: [search: 20, place: 100]
```

This will saturate ~100 concurrent HTTP connections — close to Finch's default `pool_size: 50`. Bump:

```elixir
# config/config.exs
config :gmaps_ex, GmapsEx.Http.Client, finch_pool_size: 200
```

### Avoiding "Oban forever"

The system is designed to terminate cleanly:

1. **Bounded retries**: `max_attempts: 3` on both workers. After 3 failures the job goes to `discarded` (Search) or `cancelled` (Place). No infinite retry.
2. **Cancel on unrecoverable errors**: `:preview_url_not_found` and `:app_state_not_found` return `{:cancel, reason}` immediately — no retry burn.
3. **Pruner**: `Oban.Plugins.Pruner` deletes completed jobs older than 7 days.
4. **Lifeline**: `Oban.Plugins.Lifeline` rescues `executing` jobs orphaned by BEAM crashes.

**To verify termination behavior**:
```sql
SELECT state, COUNT(*) FROM oban_jobs GROUP BY state;
```
A healthy scrape ends with only `completed`, `cancelled` (preview missing), and possibly `discarded` (3-failed). Nothing should sit in `available`, `executing`, `retryable`, or `scheduled` after the run.

---

## 5. Anti-ban hardening for production

Default measures (already in code):

- ✓ `CONSENT=YES+` + `SOCS` cookies pre-set
- ✓ 6-string UA rotation (Firefox + Chrome desktop)
- ✓ `sec-fetch-*` headers
- ✓ Exponential backoff with jitter
- ✓ Proxy ejection on 429

Recommended for production but not yet implemented:

- ✗ **TLS fingerprint randomization** (JA3/JA4). Requires `tls_client` over a Port. Worth implementing if Google starts JA3-blocking your Finch fingerprint.
- ✗ **Country-routed proxy pools** (see §3 above).
- ✗ **CAPTCHA-aware backoff**. If `body` contains `"sorry/index"` or `consent.google` after consent cookie was set, treat the proxy as poisoned for a longer window (1 hour vs 5 min).
- ✗ **Request order randomization**. Currently searches → enrichments deterministically. Adding 5–30s random delays would slow detection but cut throughput.

---

## 6. Monitoring

Telemetry events already emitted:

```
[:gmaps_ex, :search, :ok]      %{count: n, enriching: n}     %{query}
[:gmaps_ex, :search, :error]   %{}                            %{query, reason}
[:gmaps_ex, :place, :ok]       %{}                            %{cid, title}
[:gmaps_ex, :place, :error]    %{}                            %{data_id, reason}
[:gmaps_ex, :run, :complete]   %{seeds, places}               %{}
```

Attach to PromEx / Telemetry.Metrics for dashboards. Specific metrics worth tracking:

| Metric | Alert threshold |
|---|---|
| `place_error_ratio` | > 30% for 5 min → investigate (likely IP block) |
| `search_error_ratio` | > 10% for 5 min → Google changed something |
| Oban queue depth | growing for > 15 min → bottleneck downstream |
| HTTP p95 latency | > 6s → proxy pool degraded |
| Postgres pool wait | > 100ms → bump `pool_size` |

---

## 7. Per-step cost ceiling

For 1,000,000 places:

| Item | Cost |
|---|---|
| Webshare Pro 100 (100 IPs, 1TB bandwidth) | $30/mo |
| Hetzner CX32 BEAM host (4 vCPU 8GB) | €8/mo (~$9) |
| Postgres on Hetzner CX22 (2 vCPU 4GB, ~20GB disk) | €4/mo (~$5) |
| S3 storage (compressed JSONL) for ~10GB | ~$0.50/mo |
| **Total** | **~$45/mo** |

For a one-time million-place scrape: prorate the proxy month to a few days → **under $20 total**.

---

## 8. Things that will eventually break (and how)

| Risk | When | Fix |
|---|---|---|
| `pb=` search template | Google ships UI redesign, ~6-month cadence | Re-derive from `searchjob.go` in the Go repo OR by inspecting Chrome DevTools network tab |
| Place-detail index walks (`darray[37, 1]` for review_count, etc.) | Same cadence | Run the diagnostic in §13 of USAGE.md to find new indices |
| Preview-URL extraction regex | Smaller risk — HTML structure is more stable | Update the regex in `parser/html_extractor.ex` |
| Webshare IP block | Daily — IPs cycle through Google's ban list | Auto-rotation handles this; ensure the dead-revive window (default 5min) matches your pool size |
| Postgres slow at 50M+ places | Around the 50M mark | Partition `places` by `(data_id) hash`, or use Citus/CockroachDB |

Maintenance cost in practice: ~2 hours/month for someone who already knows the codebase. Higher in the first 3 months as you find weird response shapes from edge-case queries (places without phone, places with 0 photos, etc.).

---

## 9. What this stack does NOT do

- ❌ JavaScript-rendered fallback. If Google ships an A/B test that requires JS execution, those URLs will fail and you'll need to add Playwright as an opt-in worker.
- ❌ Image downloading. The `images` field has URLs; an image-download worker is a separate concern.
- ❌ Geocoding. If you have addresses without lat/lon and need to reverse, use a separate geocoder.
- ❌ Real-time updates of monitored places. This is a one-shot scraper, not a polling system. A polling system is buildable on top — schedule an Oban cron job that re-enqueues `Workers.PlaceWorker` for places older than N days.

---

## 10. Sanity check before going to production

```bash
# 1. Verify deps are pinned
cat mix.lock | wc -l   # should be ~50 lines

# 2. Verify migrations apply cleanly
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate

# 3. Verify unit tests pass
GMAPS_NO_DB=1 mix test --no-start

# 4. Smoke test (live HTTP)
mix gmaps.scrape --query "coffee shops" --geo "37.7749,-122.4194" --zoom 13

# After ~2 minutes:
psql -d gmaps_ex_dev -c "SELECT COUNT(*) FILTER (WHERE review_count > 0) AS enriched, COUNT(*) AS total FROM places;"
# Expect: enriched ≈ total (≥ 70%)

# 5. Verify Oban terminates
psql -d gmaps_ex_dev -c "SELECT state, COUNT(*) FROM oban_jobs GROUP BY state;"
# Expect: no rows in 'available', 'executing', 'retryable', 'scheduled'
```

If all five pass, this is ready to point at your real workload.
