# GAPS — what GmapsEx does NOT ship (and how to add it)

Honest gap analysis vs. the Go reference scraper at [gosom/google-maps-scraper](https://github.com/gosom/google-maps-scraper). Sorted by feasibility for users who want to close them.

See `COMPARISON.md` for the full head-to-head.

---

## Out of scope by design

These won't ship in this library because they're either non-Elixir concerns or independent products.

| Go feature | Why we don't ship it | Workaround |
|---|---|---|
| **SaaS edition** (admin UI, 2FA, multi-user, billing, cloud provisioning) | A library shouldn't ship a product. The library *is* the building block — you build your SaaS on top. | Use `EMBEDDING.md` patterns + `mix phx.gen.auth` in your host app. |
| **AWS Lambda mode** | Stateful Oban + BEAM don't fit Lambda's model. | Use `Fly.io` / Hetzner / EC2 — see `PRODUCTION.md`. |
| **DigitalOcean / Hetzner provisioning scripts** | Ops layer above the library. | Use any Elixir release tooling. |
| **LeadsDB integration** | Their commercial product. ~50 LOC to add a `LeadsDbWriter` if you want it. | Write a small Oban worker that posts to LeadsDB's REST API after `PlaceWorker` completes. |
| **Anonymous telemetry collection** | We don't phone home. | Use your own PromEx/Datadog if you want metrics. |
| **Sponsor banner ads in README** | Library, not a product. | — |

## Closable in days

Code-shaped gaps your team could ship.

### 1. Full review pagination (most impactful for SWOT/agents)

**Problem**: Google's `/maps/rpc/listugcposts` returns `[null, null, …, 1]` for unauthenticated HTTP, even with `NID`/`SOCS` cookies. The Go scraper sidesteps by running the RPC inside a Playwright browser context. **Confirmed empirically** in this codebase (see `lib/gmaps_ex/reviews.ex` module doc).

**Fix path**: Implement `GmapsEx.Reviews.Backend` with Playwright. ~150 LOC + Chromium dependency (~200 MB). See the behaviour docs at `lib/gmaps_ex/reviews/backend.ex` — there's a full implementation template.

**Current state**: ~8 inline reviews per place are persisted automatically by `PlaceWorker` (sufficient for sentiment sampling on small/medium places, insufficient for thorough analysis of chains).

### 2. REST API with OpenAPI docs

**Go has**: `POST /api/v1/jobs`, `GET /jobs`, `GET /jobs/{id}`, `DELETE /jobs/{id}`, `GET /jobs/{id}/download`, full Swagger.

**We have**: `mix gmaps.scrape` CLI + Phoenix LiveView in `gmaps_dash/`. No external API.

**Fix path**: Add a controller in your host Phoenix app:

```elixir
defmodule MyAppWeb.GmapsApiController do
  use MyAppWeb, :controller

  def create(conn, %{"query" => q, "lat" => lat, "lon" => lon} = params) do
    {:ok, n} = GmapsEx.Runner.start([%{
      query: q, lat: lat, lon: lon, zoom: params["zoom"] || 13,
      lang: params["lang"] || "en", gl: params["gl"] || "us",
      tenant_id: get_tenant_id(conn)
    }])

    json(conn, %{enqueued: n})
  end

  def index(conn, _), do: json(conn, %{places: GmapsEx.Repo.all(GmapsEx.Place)})
  def show(conn, %{"id" => id}), do: json(conn, %{place: GmapsEx.Repo.get(GmapsEx.Place, id)})
end
```

Add OpenAPI spec via `open_api_spex` (~30 LOC of `defmodule MyApiSpec`).

### 3. Custom input IDs (`#!#`)

**Go**: `Matsuhisa Athens #!#mycustomid` in input file tags every result with `mycustomid`.

**We have**: The `--input` parser already strips `#!#` suffixes but discards the ID. To plumb it through:

```elixir
# In lib/mix/tasks/gmaps.scrape.ex:load_input_file/1, return tuples:
{q, id}

# In build_seeds, add :input_id to the seed map.
# In SearchWorker, propagate via Oban job args.
# In Places.upsert, write to places.input_id.
```

`places.input_id` already exists in the schema. ~20 LOC of plumbing.

### 4. Docker image for one-command run

**Go**: `docker run gosom/google-maps-scraper -input /queries.txt -results /out/results.csv`

**We have**: `Dockerfile` (now in the repo). Build with `docker build -t gmaps_ex .`. Run with:

```bash
docker run -v "$PWD/queries.txt:/app/queries.txt:ro" -v "$PWD/out:/app/out" \
  -e DATABASE_URL="postgres://user:pass@host:5432/gmaps" \
  gmaps_ex \
  mix gmaps.scrape --input /app/queries.txt --geo "30.78,30.99" --gl eg --csv /app/out/results.csv
```

### 5. Kubernetes deployment manifests

**Go**: K8s YAML in README.

**We have**: Same architecture works (it's just a release + Postgres) — Elixir releases via `mix release` and a thin `K8s` Deployment YAML around the Docker image. Worth providing in `k8s/` directory if you deploy that way.

## Closable but limited value

### 6. AI Agent skill package

**Go**: `npx skills add gosom/google-maps-scraper` installs a Claude/Cursor skill.

**Ours**: Any agent can already call `GmapsEx.search/2` or shell out to `mix gmaps.scrape` — no special wrapper needed because the public API is itself agent-friendly. If you want the same packaging for npm, mirror the structure of `google-maps-scraper-main/skills/`.

### 7. `-fast-mode` vs normal mode

**Go**: `-fast-mode` skips per-place enrichment, returns only the 13 fields from the search XHR.

**Ours**: We *always* run search XHR for the base fields, then optionally enrich. You get fast mode by setting `args["enrich"] = false` in SearchWorker job args, OR don't enqueue PlaceWorker (small tweak to SearchWorker logic).

### 8. `-radius` strict filtering

**Go**: `-radius 5000` filters results to a 5km radius of `--geo` center.

**Ours**: Not yet. The search XHR doesn't strictly clip to radius (it returns the viewport feed). To get strict filtering, post-filter places by lat/lon haversine distance in `SearchWorker` before upserting.

### 9. `-exit-on-inactivity`

**Go**: Auto-exits if no new jobs for N minutes — useful for finite scrapes.

**Ours**: We exit when the Exiter's counters balance OR on `--timeout`. Add an inactivity tracker GenServer if needed.

---

## Closable in minutes

### 10. `--json` single-file array vs `--jsonl`

**Ours**: Both are supported (`--csv`, `--jsonl`, `--json`). The `--json` flag writes a single JSON array file (matches Go's `-json`).

### 11. `mix gmaps.export --where` filtering

**Ours**: Already supported. `mix gmaps.export --csv top.csv --where "review_rating >= 4.5 AND review_count >= 100"`.

---

## What we ship *better* than the Go scraper

This is the "why pick us" side of the matrix.

| Feature | GmapsEx | Go scraper |
|---|---|---|
| **Embed as a library in another app** | ✅ Single dep, native types | ❌ Separate binary or REST hop |
| **Native Phoenix LiveView integration** | ✅ `Phoenix.PubSub` events out of the box | ❌ Polling the REST API |
| **No browser, lower RAM** | ✅ ~250 MB at sustained concurrency | ⚠️ ~1.5 GB with Chromium |
| **Smaller codebase to fork/audit** | ~3,000 LOC | ~10,000 LOC |
| **Per-proxy rate limiter** explicit | ✅ Hammer-based | ⚠️ Implicit via concurrency cap |
| **Multi-tenant scoping** | ✅ `tenant_id` column built in | ❌ Single-tenant |
| **Ecto schemas** | ✅ Type-safe queries | ⚠️ Raw `pgx` queries |
| **Pluggable reviews backend** | ✅ `Reviews.Backend` behaviour | ❌ Hard-coded Playwright |

---

## How to read this document

If you're evaluating whether to use GmapsEx for a project:

1. Read **"Out of scope by design"** — if you need SaaS/Lambda/LeadsDB and don't want to build them, use the Go scraper.
2. Read **"Closable in days"** — if these gaps matter, budget for them.
3. Read **"What we ship better"** — if these match your needs, you're choosing the right tool.

If you find a gap not listed here, open an issue. Honest gap analysis beats marketing claims.
