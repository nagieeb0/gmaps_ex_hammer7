# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-22

Initial release.

### Added

- **Search XHR client** — direct calls to `https://maps.google.com/search?tbm=map&pb=...`, no browser
- **Place-detail two-step XHR** — `/maps/place/?ftid=…` → extract preview URL → `/maps/preview/place?pb=…` → 30 fields parsed
- **Inline reviews** — 4–8 most recent reviews per place persisted to `reviews` table automatically
- **Worldwide support** — `lang`/`gl` propagation through Runner, SearchWorker, PlaceWorker
- **Grid mode** — split a bounding box into cells, search per cell (`Runner.grid_seeds/4`)
- **Email extraction worker** — opt-in website crawl + regex extraction
- **Multi-tenant scoping** — `tenant_id` column + composite unique index
- **`has_many :reviews`** on `Place` for Ecto preload
- **Pluggable reviews backend** — `GmapsEx.Reviews.Backend` behaviour for swapping in a browser-based fetcher
- **Session cookie store** — `GmapsEx.Http.SessionStore` per-pool jar (NID/SOCS), warms from `maps.google.com`
- **Proxy pool** — round-robin GenServer, Webshare native format (`host:port:user:pass`), dead-IP ejection
- **Per-proxy rate limiter** — Hammer-backed, configurable RPS
- **Three output sinks** — `Output.Csv` (NimbleCSV, matches Go scraper columns), `Output.Jsonl`, `Output.S3` (optional ExAws)
- **Oban-backed workers** — search/place/reviews/emails queues, persistent retries, unique-job constraints
- **PubSub broadcast** — `gmaps:events` topic for LiveView dashboards
- **`mix gmaps.scrape`** — full CLI with multi-query (`--query` repeatable), `--csv`, `--jsonl`, `--grid-bbox`, dynamic concurrency tuning
- **`mix gmaps.export`** — bulk export of existing places to CSV / JSONL / S3
- **51 tests passing** — parser, RPC, dedupe, exiter, places, reviews persistence, runner, CSV
- **Docs** — README, USAGE.md, EMBEDDING.md, PRODUCTION.md, COMPARISON.md (vs Go scraper), GAPS.md

### Known limitations

- **Full review pagination** — `/maps/rpc/listugcposts` requires browser-session cookies pure HTTP can't provide. Inline ~8 reviews per place work; for the full ~300+, plug a custom `Reviews.Backend` (see module doc).
- **No JS-rendered fallback** — when Google ships a JS-only A/B variant for some queries, those URLs will fail. Documented in COMPARISON.md.
- **No LeadsDB integration** — the Go scraper has it; add ~50 LOC if you need it.
