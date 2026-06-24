# How GmapsEx Actually Works

You asked: *"do we are working right or i have not understand it well?"* — here's the complete picture, traced through real code.

---

## The big picture (one diagram)

```
                                  ┌──────────────────────────────────────┐
                                  │   YOUR APP (Phoenix / agent / CLI)   │
                                  └────────────┬─────────────────────────┘
                                               │
                  GmapsEx.search/2      GmapsEx.Runner.start/1     mix gmaps.scrape
                       (one-shot)            (persisted)              (CLI)
                                               │
                                               ▼
                                  ┌──────────────────────────────────────┐
                                  │   Oban queue: :search                │   ◄── 15 concurrent
                                  │   GmapsEx.Workers.SearchWorker       │
                                  └────────────┬─────────────────────────┘
                                               │ HTTP XHR
                                               ▼
                              maps.google.com/search?tbm=map&pb=…
                                               │ JSON (20 places)
                                               ▼
                                  ┌──────────────────────────────────────┐
                                  │   GmapsEx.Parser.Search              │
                                  │     ↓                                │
                                  │   ETS dedupe (data_id)               │
                                  │     ↓                                │
                                  │   Places.upsert (Postgres)           │
                                  │     ↓                                │
                                  │   Phoenix.PubSub: :places_found      │
                                  └────────────┬─────────────────────────┘
                                               │ enqueue 1 PlaceWorker per place
                                               ▼
                                  ┌──────────────────────────────────────┐
                                  │   Oban queue: :place                 │   ◄── 25 concurrent
                                  │   GmapsEx.Workers.PlaceWorker        │
                                  └────────────┬─────────────────────────┘
                                               │ HTTP call 1
                                               ▼
                            www.google.com/maps/place/?ftid=…&hl=…&gl=…
                                               │ HTML page
                                               ▼
                       Extract /maps/preview/place URL from preload tag
                                               │ HTTP call 2
                                               ▼
                          www.google.com/maps/preview/place?pb=…
                                               │ JSON (full detail)
                                               ▼
                                  ┌──────────────────────────────────────┐
                                  │  GmapsEx.Parser.Place                │
                                  │   • title, phone, website, hours…   │
                                  │   • review_count, review_rating     │
                                  │   • inline reviews (~8)             │
                                  │   • categories, address, owner…     │
                                  │     ↓                                │
                                  │  Places.upsert (UPDATE same row by  │
                                  │  data_id — does NOT create new)     │
                                  │     ↓                                │
                                  │  ReviewsPersistence.bulk_upsert     │
                                  │  (4-8 reviews per place)            │
                                  │     ↓                                │
                                  │  Phoenix.PubSub: :place_enriched    │
                                  └────────────┬─────────────────────────┘
                                               │ (optional, if extract_emails: true)
                                               ▼
                                  ┌──────────────────────────────────────┐
                                  │   Oban queue: :emails                │   ◄── 5 concurrent
                                  │   GmapsEx.Workers.EmailWorker        │
                                  └────────────┬─────────────────────────┘
                                               │ fetch website + /contact /about pages
                                               ▼
                                       regex match emails
                                               │
                                               ▼
                                  ┌──────────────────────────────────────┐
                                  │  UPDATE places SET emails = $1       │   ← same row, no duplicate
                                  │  WHERE data_id = $2                  │
                                  └──────────────────────────────────────┘
                                               │
                                               ▼
                                  ┌──────────────────────────────────────┐
                                  │  Postgres: places + reviews tables   │
                                  └──────────────────────────────────────┘
```

---

## Step-by-step: what happens to a single place

Following one entry through the system — say **مقهى نجيب محفوظ** (the famous Cairo café) — from query to your agent.

### 1. You make a request

```elixir
GmapsEx.Runner.start([%{
  query: "مقاهي",
  lat: 30.0444, lon: 31.2357,
  zoom: 13, lang: "ar", gl: "eg",
  tenant_id: "user-42"
}])
```

This inserts **1 row into `oban_jobs`** with worker `SearchWorker` and `state = "available"`.

### 2. Search worker picks it up

The first idle Oban worker in the `:search` queue dequeues that job. `SearchWorker.perform/1` runs.

It calls:
```elixir
GmapsEx.search("مقاهي", lat: 30.0444, lon: 31.2357, zoom: 13, lang: "ar")
```

Internally:
```
GmapsEx.PbBuilder builds:  pb=!4m12!1m3!1d…!2d31.2357!3d30.0444…
HTTP GET → https://maps.google.com/search?tbm=map&authuser=0&hl=ar&q=مقاهي&pb=…
Response: )]}'\n{garbage prefix}\n[[[null,null,null,…20 places…]]]
```

`GmapsEx.Parser.Search.parse/1` walks the nested array at fixed indices and produces 20 `%Place{}` structs — each with **title, category, rating, review_count, lat/lon, phone, hours, status, timezone, data_id**.

### 3. Search worker upserts and fans out

For each parsed place:

```elixir
# Skip if we've seen this data_id this run (ETS dedup):
Dedupe.add_if_not_exists(place.data_id)   # returns true if new

# Insert OR update (ON CONFLICT data_id):
Places.upsert(%{
  data_id: "0x...!1s0x...",
  title: "مقهى نجيب محفوظ",
  category: "مقهى",
  review_rating: 4.2,
  review_count: 5319,
  latitude: 30.0444, longitude: 31.2357,
  tenant_id: "user-42",
  input_id: nil           # nil means "no source tag"; can be set via --input or seed
})
```

The Postgres unique index on `(data_id)` means this is **idempotent** — re-running the same scrape doesn't create duplicates, it updates the row.

Then, for each new place, **enqueue 1 PlaceWorker job**:

```elixir
PlaceWorker.new(%{"data_id" => "0x...", "lang" => "ar", "gl" => "eg", "tenant_id" => "user-42"})
```

20 places → 20 new rows in `oban_jobs`, queue `:place`.

### 4. Place worker enriches

Each PlaceWorker picks one place and does **two HTTP calls**:

```
HTTP GET → /maps/place/?ftid=0x...&hl=ar&gl=eg
   ↓ extract <link href="/maps/preview/place?pb=…" as="fetch"> from HTML
HTTP GET → /maps/preview/place?pb=…
   ↓ )]}'-prefixed JSON, ~150 KB
```

`GmapsEx.Parser.Place.parse/1` walks ~50 fixed indices in that JSON to produce a **fully-populated** `%Place{}` with: address, complete_address (street/city/state/country), website, plus_code, popular_times, owner, about (services), images, reservations, order_online, status, description, **inline reviews (~8 with author/rating/date/text)**.

Then:
```elixir
attrs = Place.to_attrs(place) |> Map.put(:tenant_id, "user-42")
Places.upsert(attrs)   # SAME row as before — UPDATE, no duplicate
```

The places table now has the complete record. **One row per real-world clinic.** `data_id` is the unique key Google never reassigns.

Inline reviews go to the `reviews` table:
```elixir
ReviewsPersistence.bulk_upsert(place.id, inline_reviews)
# upserts on (place_id, name, when) so same author + same date doesn't duplicate
```

PubSub broadcast:
```elixir
Phoenix.PubSub.broadcast(GmapsEx.PubSub, "gmaps:events",
  {:place_enriched, "مقهى نجيب محفوظ", 5319, 4.2, 8})
```

Your LiveView dashboard sees this and adds the row to the live table.

### 5. Optional: email extraction

If `args["extract_emails"] == true` (or you call `Workers.EmailWorker.enqueue_for_pending/0` later):

```elixir
EmailWorker.new(%{"place_id" => place.id})  # → :emails queue
```

EmailWorker visits the place's website + `/contact` + `/about` etc., regex-matches emails, and:
```elixir
place |> Ecto.Changeset.change(emails: merged) |> Repo.update()
```

Again — **same row**, just the `emails` array column gets populated.

### 6. Your agent queries the data

```elixir
import Ecto.Query

GmapsEx.Place
|> where([p], p.tenant_id == ^current_user.tenant_id)
|> where([p], ilike(p.category, "%مقهى%"))
|> where([p], p.review_count > 100)
|> order_by([p], desc: p.review_count)
|> preload(:reviews)                                          # ← join in inline reviews
|> GmapsEx.Repo.all()
```

You get back fully-formed Elixir structs with all 33 fields + their inline reviews. Feed those to your LLM for SWOT.

---

## What's actually in the DB after a scrape

Three tables that matter:

```
places                                 reviews
─────────                              ─────────
id (UUID)                              id (UUID)
data_id (unique) ◄──────────────┐      place_id ──────►  places.id
title                            │     name
category                         │     rating
categories[]                     │     description
address, latitude, longitude     │     when
phone, website, plus_code        │     images[]
review_rating, review_count      │
reviews_per_rating (jsonb)       │
hours (jsonb), popular_times     │
about (jsonb), images (jsonb)    │
reservations, order_online       │
owner (jsonb)                    │
complete_address (jsonb)         │     oban_jobs
emails[]                         │     ─────────
input_id (custom tag)            │     id, state (available/executing/completed/cancelled/discarded)
tenant_id                        │     worker, queue, args, errors
inserted_at, updated_at          │     attempted_at, completed_at
                                 │
                                 └─ data_id is the cross-call stable key
```

A single clinic is **one row in `places`**, optionally **N rows in `reviews`**, and **0 or more closed rows in `oban_jobs`** (one per scrape pass).

---

## Guarantees

| Property | How it's enforced |
|---|---|
| **No duplicate places** | `unique_index(:places, [:data_id])` + ON CONFLICT |
| **No duplicate reviews** | `unique_index(:reviews, [:place_id, :name, :when])` + ON CONFLICT |
| **Updates don't reset old data** | `ON CONFLICT … DO UPDATE SET …` only replaces the fields the new payload contains; nulls in the new payload don't overwrite existing non-null values (we use `replace_all_except: [:id, :inserted_at]`, but search-level upserts pass nil for fields they don't know, which *does* overwrite. **The fix**: PlaceWorker runs after SearchWorker, so the rich enrichment overwrites the partial search data — never the other way around) |
| **Idempotent re-scraping** | Oban `unique` constraints on job args prevent duplicate searches within 1h; ETS dedup handles within-run; data_id index handles across-run |
| **Tenant isolation** | `tenant_id` column + composite unique on `(tenant_id, data_id)` lets multiple tenants scrape the same place independently |
| **No infinite Oban loops** | `max_attempts: 3` on every worker; `:cancel` returns on unrecoverable errors; Oban Pruner deletes completed jobs > 7 days old |

---

## When something looks wrong

| Symptom | Where to look | What it means |
|---|---|---|
| Place count grows beyond `unique data_id count` | `psql -c "SELECT data_id, count(*) FROM places GROUP BY 1 HAVING count(*) > 1"` | Bug — file an issue |
| `oban_jobs` `state = 'retryable'` for a while | `SELECT errors[1] FROM oban_jobs WHERE state = 'retryable'` | Transient failure; will retry in seconds-minutes |
| `state = 'discarded'` | Reason in `errors` JSONB | Permanent failure for that data_id (Google didn't include preview link, etc.). Re-running the scrape may pick it up next time. |
| `places.emails` empty | EmailWorker wasn't run | `iex> Workers.EmailWorker.enqueue_for_pending()` to backfill |
| Reviews not showing for a place | `Repo.preload(:reviews)` missing in your query | Default Ecto query doesn't preload associations |

---

## The mental model in one paragraph

You enqueue a *seed* (query + location + tenant). The library spawns a tree of background jobs: 1 search → ~20 places → ~20 enrichments → optional email crawls. Each step writes to Postgres via Ecto upserts keyed on Google's stable `data_id`, so it's safe to run any seed multiple times without dedup pain. Your agent reads from `places` and `reviews` via plain Ecto queries. PubSub events let you build a live UI on top.

That's it. No magic. No black boxes.
</thinking>
