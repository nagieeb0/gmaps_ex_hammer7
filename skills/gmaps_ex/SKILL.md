---
name: gmaps-ex
description: |
  Use GmapsEx to scrape Google Maps business data (places, reviews, contact info)
  for any geographic area. Returns structured Elixir data — title, rating,
  review_count, phone, website, hours, address, lat/lon, categories, inline
  reviews. Pure HTTP, no browser. Embeds as an Elixir library in any
  Phoenix/Elixir app.
trigger_phrases:
  - "find me dentists in"
  - "scrape competitors of"
  - "every café in"
  - "all restaurants near"
  - "business data for"
  - "competitor analysis for"
  - "SWOT data for"
homepage: https://hex.pm/packages/gmaps_ex
---

# GmapsEx — Agent Skill

You are operating inside an Elixir/Phoenix app that has `gmaps_ex` as a dependency. This skill teaches you to use it correctly to fulfill business-data queries.

## Mental model

`gmaps_ex` calls Google Maps' XHR endpoints directly and persists results to a Postgres database via Ecto. You access scraped data through the `GmapsEx.Place` schema. Background jobs (Oban) handle the actual scraping; you trigger them via `GmapsEx.Runner.start/1` or `GmapsEx.search/2` (for one-shot calls without persistence).

## Decision tree

When a user asks for business data:

1. **One-shot, transient lookup (no DB)** → `GmapsEx.search/2`
2. **Persist to DB for later analysis** → `GmapsEx.Runner.start/1` (multi-job + dedupe)
3. **Bulk regional sweep (all of a city)** → `mix gmaps.scrape` with `--grid-bbox`
4. **A whole country / multiple regions** → Custom Mix task tiling cities (see `gmaps.egypt.ex` for the pattern)

## Recipes

### Recipe 1 — quick one-shot

User: *"What are the top coffee shops in San Francisco?"*

```elixir
{:ok, places} = GmapsEx.search("coffee shops",
  lat: 37.7749, lon: -122.4194, zoom: 13)

# `places` is a list of %GmapsEx.Place{} structs, NOT persisted.
# Use for ephemeral queries that don't need DB storage.
```

### Recipe 2 — persisted scrape (single query × geo)

User: *"Find every dentist in Cairo and save them."*

```elixir
{:ok, _enqueued} = GmapsEx.Runner.start([%{
  query: "dentist",
  lat: 30.0444, lon: 31.2357,
  zoom: 13, lang: "en", gl: "eg",
  tenant_id: current_user.tenant_id
}])

# Then poll the DB:
import Ecto.Query
GmapsEx.Place
|> where([p], ilike(p.category, "%dental%") or ilike(p.title, "%dentist%"))
|> where([p], p.tenant_id == ^current_user.tenant_id)
|> order_by([p], desc: p.review_count)
|> GmapsEx.Repo.all()
```

### Recipe 3 — competitor SWOT analysis

User: *"Give me a SWOT analysis of dental clinics in Mansoura."*

```elixir
# 1. Scrape (if not done already)
GmapsEx.Runner.start([%{
  query: "عيادة أسنان",
  lat: 31.04, lon: 31.38, zoom: 14,
  lang: "ar", gl: "eg"
}])

# 2. Wait for completion (or poll periodically)
Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")
receive do {:place_enriched, _, _, _, _} -> :ok end

# 3. Query competitor data + reviews
clinics = GmapsEx.Place
  |> where([p], ilike(p.category, "%عيادة أسنان%"))
  |> where([p], p.review_count > 50)
  |> order_by([p], desc: p.review_count)
  |> preload(:reviews)
  |> GmapsEx.Repo.all()

# 4. Feed to your LLM
reviews_corpus =
  clinics
  |> Enum.flat_map(& &1.reviews)
  |> Enum.filter(&(&1.rating <= 3))   # negative reviews = SWOT weaknesses
  |> Enum.map(& "[#{&1.rating}★] #{&1.description}")
  |> Enum.join("\n---\n")

prompt = """
Analyze these competitors and reviews. Produce a SWOT matrix.

Competitors:
#{Enum.map_join(clinics, "\n", &"- #{&1.title} (#{&1.review_rating}★, #{&1.review_count}rv)")}

Negative reviews (weaknesses):
#{reviews_corpus}
"""
```

### Recipe 4 — bulk export

User: *"Export all dental clinics with their emails."*

```bash
# CLI — runs scrape + email enrichment + writes CSV
mix gmaps.scrape \
  --query "dental clinic" \
  --grid-bbox "30.0,31.0,30.2,31.4" --grid-cell-km 1.5 \
  --gl eg --lang ar \
  --csv dental.csv --json dental.json
```

Then call `Workers.EmailWorker.enqueue_for_pending/0` from IEx to crawl websites and extract emails.

### Recipe 5 — agentic loop

User asks: *"Compare my coffee shop in Tanta with competitors."*

```elixir
def analyze_for_user(user_business) do
  # 1. Scrape competitors in their geo
  GmapsEx.Runner.start([%{
    query: "coffee shops",
    lat: user_business.lat,
    lon: user_business.lon,
    zoom: 14,
    lang: detect_lang(user_business),
    gl: user_business.country_code,
    tenant_id: user_business.tenant_id
  }])

  # 2. Subscribe to live updates
  Phoenix.PubSub.subscribe(GmapsEx.PubSub, "gmaps:events")

  # 3. Wait for completion (timeout 60s for ~20 places + enrichment)
  wait_for_completion(60_000)

  # 4. Pull competitors from DB
  competitors = nearby_competitors(user_business, radius_km: 3)

  # 5. Feed to LLM
  llm_call(competitors, user_business)
end
```

## Fields per place (33 of them)

```
title, category, categories, address, complete_address (jsonb breakdown),
phone, website, latitude, longitude, plus_code,
review_rating, review_count, reviews_per_rating,
open_hours (jsonb), popular_times (jsonb), status (open/closed),
data_id (Google stable ID), cid, place_id,
images, reservations, order_online, menu, owner,
about (services + amenities), thumbnail, timezone, price_range,
reviews (has_many association, 4-8 inline reviews each),
emails (populated by Workers.EmailWorker — opt-in),
input_id (custom tag passed via #!# or seed),
tenant_id (multi-tenant scoping)
```

## Worldwide support

Every `lang`/`gl` Google supports works. Examples:

| Country | `gl` | Common `lang` |
|---|---|---|
| Egypt | `eg` | `ar` |
| US | `us` | `en` |
| UK | `gb` | `en` |
| France | `fr` | `fr` |
| Japan | `jp` | `ja` |
| Brazil | `br` | `pt` |
| Germany | `de` | `de` |
| Saudi | `sa` | `ar` |

## Rate limits & costs

Single IP without proxies: ~5 req/sec sustained. ~5,000 places/hour realistic. Google rate-limits per IP — *not* per language/country.

With Webshare residential proxies (~$30/mo for 100 IPs): 25,000+ places/hour.

## What you CAN'T get

- **More than ~8 reviews per place** — Google's review-pagination RPC requires browser-session cookies. Pure HTTP gets the 8 inline reviews from the place-detail XHR. For full pagination you'd need a Playwright fallback (not built into the library by default).
- **Real-time data** — places update on Google's schedule. Re-scrape every 7-30 days for fresh review counts.

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `:preview_url_not_found` | Google didn't include the preload link for this place | Re-scrape later; happens to ~1-5% of places |
| `:place_json_not_found` | Place HTML didn't have the expected JSON section | Same as above — Google A/B variant |
| Empty results | Wrong `gl`/`lang` for the region | Match `gl` to the country (e.g. `eg` for Egypt) |
| 429s in logs | Hitting Google's rate limit | Add proxies via `GMAPS_PROXIES` env |

## Verbal patterns to recognize

When the user says:

- "Find me X in Y" → `GmapsEx.Runner.start([%{query: X, ...Y_coords...}])`
- "Get the competitors of my business" → grid scrape around their lat/lon
- "Analyze the dental market in Cairo" → full city scrape + LLM SWOT
- "Build a lead list" → scrape + `EmailWorker.enqueue_for_pending`
- "Refresh data for X" → re-run `Runner.start/1` for the same query (dedupe by data_id handles updates)

## Don't do these things

- ❌ Call Google's URLs directly. Use `GmapsEx.search/2` or `Runner.start/1`.
- ❌ Pass user-supplied lat/lon without validation (could crash if not floats).
- ❌ Forget `gl` for non-US queries — Google's geo-routing will override your viewport.
- ❌ Set Oban concurrency above ~20 on a single IP without proxies — hits 429s.
- ❌ Trust `review_count` to be perfectly current — it's a snapshot from when the place was last scraped.

## More docs

- Full API: `https://hexdocs.pm/gmaps_ex`
- Embedding pattern: `EMBEDDING.md`
- Production scale: `PRODUCTION.md`
- Honest comparison with Go scraper: `COMPARISON.md`
- Known limitations: `GAPS.md`
