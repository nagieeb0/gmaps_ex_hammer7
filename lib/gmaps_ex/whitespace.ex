defmodule GmapsEx.Whitespace do
  @moduledoc """
  Brand-level aggregation and geographic gap analysis over the scraped `places` table.

  Works through raw SQL on the `brand_key`/`brand_name`/`district` columns added by
  migration `20260912000001`. Those columns are deliberately absent from the
  `GmapsEx.Place` schema: `Places.upsert/1` uses
  `on_conflict: {:replace_all_except, [:id, :inserted_at]}`, which enumerates schema
  fields, so declaring them would make every re-scrape reset them to NULL mid-run.
  """

  import Ecto.Query

  alias GmapsEx.{Brand, Geo, Repo}
  alias GmapsEx.Malqa.Districts

  @closed ["Permanently closed", "مغلق نهائيًا", "مغلق نهائيا", "Temporarily closed", "مغلق مؤقتًا"]

  @doc """
  Measure each district's real centre and spread from the rows whose *address*
  names a district.

  Google's Riyadh addresses are authoritative for this; hand-drawn boxes are not.
  Returns `%{tag => {lat, lon, p90_radius_km}}`, and only keeps districts with
  enough labelled rows to place a centroid honestly.
  """
  @spec learn_points(String.t()) :: [{float(), float(), String.t()}]
  def learn_points(prefix \\ "malqa:%") do
    Repo.all(
      from(p in "places",
        where: like(p.input_id, ^prefix) and not is_nil(p.latitude),
        select: %{lat: p.latitude, lon: p.longitude, address: p.address, ca: p.complete_address}
      ),
      timeout: :infinity
    )
    |> Enum.flat_map(fn r ->
      case Districts.from_address(r.ca, r.address) do
        nil -> []
        tag -> [{r.lat, r.lon, tag}]
      end
    end)
  end

  @spec learn_centroids(String.t(), pos_integer()) :: %{optional(String.t()) => {float(), float(), float()}}
  def learn_centroids(prefix \\ "malqa:%", min_rows \\ 8) do
    Repo.all(
      from(p in "places",
        where: like(p.input_id, ^prefix) and not is_nil(p.latitude),
        select: %{lat: p.latitude, lon: p.longitude, address: p.address, ca: p.complete_address}
      ),
      timeout: :infinity
    )
    |> Enum.flat_map(fn r ->
      case Districts.from_address(r.ca, r.address) do
        nil -> []
        tag -> [{tag, r}]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_tag, rs} -> length(rs) >= min_rows end)
    |> Map.new(fn {tag, rs} ->
      n = length(rs)
      lat = Enum.sum(Enum.map(rs, & &1.lat)) / n
      lon = Enum.sum(Enum.map(rs, & &1.lon)) / n

      p90 =
        rs
        |> Enum.map(&Geo.haversine_km(lat, lon, &1.lat, &1.lon))
        |> Enum.sort()
        |> Enum.at(min(n - 1, trunc(n * 0.9)))

      {tag, {lat, lon, max(p90, 0.6)}}
    end)
  end

  @doc """
  Derive `brand_key`, `brand_name` and `district` for every place matching `prefix`
  and write them back.

  Idempotent and re-runnable: after editing the alias table or the normalizer, run
  it again and the whole set re-keys in seconds. That cheapness is what makes the
  audit loop practical.
  """
  @spec backfill(String.t()) :: %{scanned: non_neg_integer(), updated: non_neg_integer()}
  def backfill(prefix \\ "malqa:%") do
    rows =
      Repo.all(
        from(p in "places",
          where: like(p.input_id, ^prefix),
          select: %{
            id: p.id,
            data_id: p.data_id,
            title: p.title,
            website: p.website,
            phone: p.phone,
            latitude: p.latitude,
            longitude: p.longitude,
            address: p.address,
            complete_address: p.complete_address
          }
        ),
        timeout: :infinity
      )

    points = learn_points(prefix)
    keyed = Brand.key_all(rows)

    # Resolve the display name once per brand. Doing it per row would be O(n^2)
    # and the Riyadh set is tens of thousands of rows.
    names =
      keyed
      |> Enum.group_by(fn {_row, key, _src} -> key end, fn {row, _key, _src} -> row end)
      |> Map.new(fn {key, members} -> {key, Brand.display_name(members)} end)

    updated =
      keyed
      |> Enum.map(fn {row, key, _source} ->
        district =
          Districts.from_address(row.complete_address, row.address) ||
            Districts.assign_knn(row.latitude, row.longitude, points)

        {row.id, key, Map.fetch!(names, key), district}
      end)
      |> Enum.chunk_every(500)
      |> Enum.reduce(0, fn chunk, acc -> acc + write_chunk(chunk) end)

    %{scanned: length(rows), updated: updated}
  end

  defp write_chunk(chunk) do
    {values, params, _} =
      Enum.reduce(chunk, {[], [], 1}, fn {id, key, name, district}, {vs, ps, i} ->
        {["($#{i}::uuid,$#{i + 1}::text,$#{i + 2}::text,$#{i + 3}::text)" | vs],
         # Selecting from the raw "places" source (not the schema) already yields a
         # 16-byte binary UUID, so no dump step here.
         ps ++ [id, key, name, district], i + 4}
      end)

    sql = """
    UPDATE places p
       SET brand_key = v.brand_key, brand_name = v.brand_name, district = v.district
      FROM (VALUES #{values |> Enum.reverse() |> Enum.join(",")}) AS v(id, brand_key, brand_name, district)
     WHERE p.id = v.id
    """

    %{num_rows: n} = Repo.query!(sql, params)
    n
  end

  @doc """
  Brand-level rollup with the geographic gap to the site.

  One row per brand: branch count, review-weighted rating, distance to the nearest
  branch, twin-district share, new-branch share, and the contact fields carried over
  from the branch with the most reviews.
  """
  @spec brands(keyword()) :: [map()]
  def brands(opts \\ []) do
    lat = Keyword.get(opts, :site_lat, 24.798)
    lon = Keyword.get(opts, :site_lon, 46.595)
    # Scope by harvest stage: the kitchen sweep deliberately pulls in caterers, event
    # companies and car washes, none of which belong in the restaurant white-space
    # ranking. `input_id` is how every task in this repo slices the shared table.
    prefixes = Keyword.get(opts, :prefixes, [Keyword.get(opts, :prefix, "malqa:%")])
    new_threshold = Keyword.get(opts, :new_branch_reviews, 60)

    # `gl: "eg"` plus Egyptian coordinates still leaks Riyadh results into the Egypt
    # stages — a bakery on Anas Ibn Malik came back for an Alexandria query. Trust
    # the coordinates that came with the place, not the intent of the search that
    # found it. Egypt and Saudi separate cleanly on longitude (Cairo ~31E, Riyadh ~47E).
    {min_lat, min_lon, max_lat, max_lon} =
      Keyword.get(opts, :bbox, {-90.0, -180.0, 90.0, 180.0})
    twins = Keyword.get(opts, :twins, Districts.twins())

    km = Geo.sql_km_expr("$1", "$2", "p.latitude", "p.longitude")

    sql = """
    WITH branches AS (
      SELECT p.brand_key, p.brand_name, p.title, p.district, p.website, p.phone,
             p.emails, p.categories, p.category, p.price_range, p.address,
             p.review_count, p.review_rating, p.latitude, p.longitude, p.link,
             #{km} AS km_to_site
        FROM places p
       WHERE p.input_id LIKE ANY($5::text[])
         AND p.brand_key IS NOT NULL
         AND p.latitude IS NOT NULL
         AND p.longitude IS NOT NULL
         AND coalesce(p.status,'') <> ALL($6::text[])
         AND p.latitude BETWEEN $7 AND $9
         AND p.longitude BETWEEN $8 AND $10
    )
    SELECT brand_key,
           (array_agg(brand_name ORDER BY review_count DESC NULLS LAST))[1] AS brand_name,
           count(*)                                                        AS branches,
           coalesce(sum(review_count), 0)                                  AS total_reviews,
           CASE WHEN sum(review_count) > 0
                THEN sum(review_rating * review_count)::float8 / sum(review_count)
           END                                                             AS w_rating,
           avg(review_rating) FILTER (WHERE review_rating IS NOT NULL)     AS mean_rating,
           min(km_to_site)                                                 AS d_min,
           count(*) FILTER (WHERE km_to_site <= 3.0)                       AS within_3km,
           count(*) FILTER (WHERE km_to_site <= 1.0)                       AS within_1km,
           count(*) FILTER (WHERE review_count < $3)::float8 / count(*)    AS new_branch_frac,
           count(*) FILTER (WHERE district = ANY($4::text[]))::float8 / count(*) AS twin_frac,
           count(DISTINCT district)                                        AS district_spread,
           (array_agg(district ORDER BY km_to_site ASC))[1]                AS nearest_district,
           count(DISTINCT nullif(website,''))                              AS distinct_sites,
           (array_agg(website ORDER BY review_count DESC NULLS LAST)
              FILTER (WHERE website IS NOT NULL AND website <> ''))[1]     AS website,
           (array_agg(phone ORDER BY review_count DESC NULLS LAST)
              FILTER (WHERE phone IS NOT NULL AND phone <> ''))[1]         AS phone,
           (array_agg(emails ORDER BY review_count DESC NULLS LAST)
              FILTER (WHERE coalesce(array_length(emails,1),0) > 0))[1]    AS emails,
           (array_agg(link ORDER BY review_count DESC NULLS LAST))[1]      AS link,
           (array_agg(address ORDER BY review_count DESC NULLS LAST))[1]   AS address,
           mode() WITHIN GROUP (ORDER BY categories[1])                    AS top_category,
           mode() WITHIN GROUP (ORDER BY price_range)                      AS price_range,
           array_agg(DISTINCT district)                                    AS districts,
           array_agg(DISTINCT title)                                       AS member_titles
      FROM branches
     GROUP BY brand_key
     ORDER BY count(*) DESC
    """

    %{rows: rows, columns: cols} =
      Repo.query!(
        sql,
        [lat, lon, new_threshold, twins, prefixes, @closed, min_lat, min_lon, max_lat, max_lon],
        timeout: :infinity
      )

    keys = Enum.map(cols, &String.to_atom/1)
    Enum.map(rows, fn r -> keys |> Enum.zip(r) |> Map.new() end)
  end

  @doc """
  What already trades around the site: how many F&B places sit within 800 m and
  1 km, and the category mix inside 1 km.

  This is the category white-space map — the thing that says which concepts are
  over-served on Anas Ibn Malik and which are missing.
  """
  @spec near_site(keyword()) :: map()
  def near_site(opts \\ []) do
    lat = Keyword.get(opts, :site_lat, 24.798)
    lon = Keyword.get(opts, :site_lon, 46.595)
    prefix = Keyword.get(opts, :prefix, "malqa:%")
    radius = Keyword.get(opts, :radius_km, 1.0)

    km = Geo.sql_km_expr("$1", "$2", "p.latitude", "p.longitude")

    sql = """
    WITH near AS (
      SELECT p.title, p.categories, p.category, p.review_rating, p.review_count,
             p.price_range, p.address, p.brand_key, p.brand_name,
             #{km} AS km
        FROM places p
       WHERE p.input_id LIKE $3
         AND p.latitude IS NOT NULL AND p.longitude IS NOT NULL
         AND coalesce(p.status,'') <> ALL($5::text[])
    )
    SELECT coalesce(categories[1], category, 'غير مصنف') AS cat,
           count(*) FILTER (WHERE km <= 0.8)  AS n_800m,
           count(*) FILTER (WHERE km <= $4)   AS n_radius,
           round(avg(review_rating) FILTER (WHERE km <= $4 AND review_rating IS NOT NULL)::numeric, 2) AS avg_rating,
           sum(review_count) FILTER (WHERE km <= $4) AS reviews
      FROM near
     WHERE km <= $4
     GROUP BY 1
     ORDER BY n_radius DESC
    """

    %{rows: rows} = Repo.query!(sql, [lat, lon, prefix, radius, @closed], timeout: :infinity)

    categories =
      Enum.map(rows, fn [cat, n800, nr, avg, rev] ->
        %{category: cat, n_800m: n800, n_radius: nr, avg_rating: to_f(avg), reviews: rev || 0}
      end)

    %{
      radius_km: radius,
      total: Enum.sum(Enum.map(categories, & &1.n_radius)),
      total_800m: Enum.sum(Enum.map(categories, & &1.n_800m)),
      categories: categories
    }
  end

  @doc """
  How many branches each brand has inside Saudi Arabia.

  This is the Track B tier signal, and it is *measured* rather than inferred from
  news: the `ksaprobe` stage searches each Egyptian brand name from anchors across
  Riyadh, Jeddah and Dammam, and whatever comes back carries the same derived
  `brand_key`. One to three KSA branches is the hottest state in the whole
  exercise — appetite proved, rollout underway, site hunt live.
  """
  @spec ksa_presence([String.t()]) :: %{optional(String.t()) => non_neg_integer()}
  def ksa_presence(prefixes \\ ["malqa:ksaprobe:%", "malqa:site:%", "malqa:twin:%", "malqa:kitchen:%"]) do
    sql = """
    SELECT brand_key, count(*)
      FROM places
     WHERE input_id LIKE ANY($1::text[])
       AND brand_key IS NOT NULL
     GROUP BY brand_key
    """

    %{rows: rows} = Repo.query!(sql, [prefixes])
    Map.new(rows, fn [k, n] -> {k, n} end)
  end

  @doc """
  KSA branch count per Egyptian brand, matched across scripts.

  An exact `brand_key` match misses the common case: the same chain is listed as
  "كوستا كوفي" in Cairo and "Costa Coffee" in Riyadh, so the keys differ and the
  brand looks absent from Saudi when it is everywhere. Trigram similarity on the
  brand name catches those, which is what keeps an already-landed global chain out
  of a list of brands that still need a Riyadh site.
  """
  @spec ksa_presence_fuzzy(String.t(), [String.t()], float()) ::
          %{optional(String.t()) => non_neg_integer()}
  def ksa_presence_fuzzy(
        eg_prefix \\ "malqa:eg:%",
        ksa_prefixes \\ ["malqa:ksaprobe:%", "malqa:site:%", "malqa:twin:%", "malqa:kitchen:%"],
        threshold \\ 0.62
      ) do
    sql = """
    WITH eg AS (
      SELECT brand_key, brand_name, count(*) AS n
        FROM places
       WHERE input_id LIKE $1 AND brand_key IS NOT NULL AND brand_name <> ''
       GROUP BY 1, 2
    ),
    ksa AS (
      SELECT brand_key, brand_name, count(*) AS n
        FROM places
       WHERE input_id LIKE ANY($2::text[]) AND brand_key IS NOT NULL AND brand_name <> ''
       GROUP BY 1, 2
    )
    -- MAX, not SUM: summing every near-match inflates a brand's Saudi footprint
    -- with unrelated lookalikes and buries exactly the brands we are hunting for.
    SELECT eg.brand_key, max(ksa.n) AS ksa_n
      FROM eg
      JOIN ksa
        ON eg.brand_key = ksa.brand_key
        OR (length(eg.brand_name) >= 5
            AND length(ksa.brand_name) >= 5
            AND similarity(lower(eg.brand_name), lower(ksa.brand_name)) > $3)
     GROUP BY eg.brand_key
    """

    %{rows: rows} = Repo.query!(sql, [eg_prefix, ksa_prefixes, threshold], timeout: :infinity)
    Map.new(rows, fn [k, n] -> {k, n} end)
  end

  @doc """
  Per-category demand and supply statistics, measured rather than assumed.

  For every F&B category: how many outlets carry it across the affluent north-Riyadh
  set, how many reviews they hold between them, and how many already sit inside the
  site's catchment. The ratio of those is the variable that matters —
  **reviews per outlet** is revealed demand per unit of supply, so a category with
  few outlets and enormous review mass is one the market is under-served in.
  """
  @spec category_stats(keyword()) :: %{optional(String.t()) => map()}
  def category_stats(opts \\ []) do
    lat = Keyword.get(opts, :site_lat, 24.798)
    lon = Keyword.get(opts, :site_lon, 46.595)
    prefixes = Keyword.get(opts, :prefixes, ["malqa:site:%", "malqa:twin:%"])
    km = Geo.sql_km_expr("$1", "$2", "p.latitude", "p.longitude")

    sql = """
    WITH scoped AS (
      SELECT coalesce(p.categories[1], p.category) AS cat,
             p.review_count, p.review_rating,
             #{km} AS km
        FROM places p
       WHERE p.input_id LIKE ANY($3::text[])
         AND p.latitude IS NOT NULL AND p.longitude IS NOT NULL
         AND coalesce(p.categories[1], p.category) IS NOT NULL
         AND coalesce(p.status,'') <> ALL($4::text[])
    )
    SELECT cat,
           count(*)                                       AS outlets,
           coalesce(sum(review_count), 0)                 AS reviews,
           count(*) FILTER (WHERE km <= 1.0)              AS near_1km,
           count(*) FILTER (WHERE km <= 0.8)              AS near_800m,
           avg(review_rating) FILTER (WHERE review_rating IS NOT NULL) AS avg_rating
      FROM scoped
     GROUP BY cat
    """

    %{rows: rows} = Repo.query!(sql, [lat, lon, prefixes, @closed], timeout: :infinity)

    Map.new(rows, fn [cat, outlets, reviews, n1, n8, avg] ->
      {cat,
       %{
         outlets: outlets,
         reviews: reviews,
         reviews_per_outlet: if(outlets > 0, do: reviews / outlets, else: 0.0),
         near_1km: n1,
         near_800m: n8,
         avg_rating: to_f(avg)
       }}
    end)
  end

  @doc """
  Listing-health evidence per brand — deliberately **not** called activity.

  What was wanted was proof of recent trading. That is not reachable here: the
  reviews RPC returns 403 from a single IP without a browser backend, and
  `popular_times` — the one field that would be near-proof, since Google only models
  a busyness curve for a place it still sees visits to — comes back empty from the
  place-detail endpoint for every row tested.

  What is left is weaker and is scored as such:

    * **`status`** — Google's own permanently/temporarily-closed flag. Reliable, and
      the only hard negative available.
    * **maintained listing** — hours and an "about" block present, which an
      abandoned listing usually lacks. Only ~20% of enriched rows carry hours, so
      *absence proves nothing* and is scored neutral rather than as a penalty.

  Every place in the dataset was returned by a live Google search today and not
  flagged closed, so the floor here is "listed and not closed", not "unknown".
  """
  @spec activity([String.t()]) :: %{optional(String.t()) => map()}
  def activity(prefixes \\ ["malqa:%"]) do
    sql = """
    SELECT brand_key,
           bool_or(popular_times <> '{}')                  AS has_pt,
           bool_or(open_hours <> '{}')                     AS has_hours,
           bool_or(coalesce(status,'') <> '')              AS any_closed,
           max(review_count)                               AS top_reviews
      FROM places
     WHERE input_id LIKE ANY($1::text[]) AND brand_key IS NOT NULL
     GROUP BY brand_key
    """

    %{rows: rows} = Repo.query!(sql, [prefixes], timeout: :infinity)

    Map.new(rows, fn [k, pt, hours, closed, _rc] ->
      # Narrow band on purpose: a maintained listing is a mild positive, a closed
      # flag is a real negative, and silence is neither. A wider band would let a
      # measurement gap masquerade as a judgement about the business.
      score =
        cond do
          closed -> 0.45
          pt and hours -> 1.0
          hours -> 0.95
          true -> 0.85
        end

      {k, %{has_popular_times: !!pt, has_hours: !!hours, any_closed: !!closed, score: score}}
    end)
  end

  @doc """
  Riyadh branch count per brand, matched across naming variants.

  Mirrors `ksa_presence_fuzzy/3` but asks the opposite question: of the brands
  trading strongly in Jeddah, Khobar, Qassim or Abha, which ones are **not** in
  Riyadh yet? That absence plus a proven format is the whole case for a site here.
  """
  # Riyadh proper. The brand-name scan runs at low zoom, which happily returns a
  # brand's Jeddah branches from a Riyadh anchor — counting those as Riyadh presence
  # would delete exactly the candidates the segment exists to find.
  @riyadh_box {24.45, 46.40, 25.00, 47.00}

  @spec riyadh_presence(String.t(), [String.t()], float(), non_neg_integer()) ::
          %{optional(String.t()) => non_neg_integer()}
  def riyadh_presence(
        src_prefix \\ "malqa:ksa:%",
        riyadh_prefixes \\ ["malqa:site:%", "malqa:twin:%", "malqa:kitchen:%", "malqa:brandscan:%"],
        threshold \\ 0.82,
        min_reviews \\ 300
      ) do
    {r_min_lat, r_min_lon, r_max_lat, r_max_lon} = @riyadh_box

    # Matching is done in Elixir, not SQL. Three SQL attempts at the cross-script
    # name join each ran past ten minutes: `similarity()` is a per-pair function call
    # that no index can serve, the indexable `%` operator is defeated by an OR in the
    # join condition, and splitting it did not help because a CTE is materialised and
    # so never touches the GIN index on places.brand_name at all. Two cheap indexed
    # reads plus a prefiltered comparison in Elixir is predictable and finishes in
    # seconds.
    src = brand_names(src_prefix, nil, min_reviews)
    ryd = brand_names(riyadh_prefixes, {r_min_lat, r_min_lon, r_max_lat, r_max_lon}, 0)

    by_key = Map.new(ryd, fn r -> {r.key, r.n} end)

    # Bucket Riyadh brands by the first two characters of the folded name, so each
    # source brand is compared against a handful of plausible names rather than all
    # six thousand.
    buckets =
      Enum.group_by(ryd, fn r -> String.slice(r.folded, 0, 2) end)

    Enum.reduce(src, %{}, fn s, acc ->
      exact = Map.get(by_key, s.key)

      fuzzy =
        if String.length(s.folded) >= 5 do
          buckets
          |> Map.get(String.slice(s.folded, 0, 2), [])
          |> Enum.filter(fn r ->
            String.length(r.folded) >= 5 and
              String.jaro_distance(s.folded, r.folded) >= threshold
          end)
          |> Enum.map(& &1.n)
          |> Enum.max(fn -> nil end)
        end

      case Enum.reject([exact, fuzzy], &is_nil/1) do
        [] -> acc
        ns -> Map.put(acc, s.key, Enum.max(ns))
      end
    end)
  end

  # One indexed read per side: brand, its branch count, and a folded name for
  # comparison.
  defp brand_names(prefix, bbox, min_reviews) do
    {prefixes, param} =
      case prefix do
        p when is_binary(p) -> {[p], [p]}
        list when is_list(list) -> {list, [list]}
      end

    {bbox_clause, bbox_params} =
      case bbox do
        nil -> {"", []}
        {a, b, c, d} -> {"AND latitude BETWEEN $2 AND $4 AND longitude BETWEEN $3 AND $5", [a, b, c, d]}
      end

    like =
      if length(prefixes) == 1 and bbox == nil,
        do: "input_id LIKE $1",
        else: "input_id LIKE ANY($1::text[])"

    sql = """
    SELECT brand_key, brand_name, count(*) AS n, coalesce(sum(review_count), 0) AS rv
      FROM places
     WHERE #{like} AND brand_key IS NOT NULL AND brand_name <> ''
       #{bbox_clause}
     GROUP BY 1, 2
    """

    params = if length(prefixes) == 1 and bbox == nil, do: param, else: [prefixes] ++ bbox_params

    %{rows: rows} = Repo.query!(sql, params, timeout: :infinity)

    rows
    |> Enum.filter(fn [_k, _nm, _n, rv] -> rv >= min_reviews end)
    |> Enum.map(fn [k, nm, n, _rv] -> %{key: k, n: n, folded: fold_name(nm)} end)
  end

  defp fold_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[أإآٱ]/u, "ا")
    |> String.replace("ة", "ه")
    |> String.replace("ى", "ي")
    |> String.replace(~r/[\p{P}\p{S}]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @doc """
  Brand names that were actually put through a Riyadh-wide name scan.

  "Did not appear in my data" and "was searched for across Riyadh and did not
  appear" are very different claims, and only the second is worth saying to a brand
  on the phone. Sign Burger looked absent from Riyadh on the geographic harvest alone
  and turned out to have twenty branches there.
  """
  @spec scanned_names() :: MapSet.t()
  def scanned_names do
    %{rows: rows} =
      Repo.query!("""
      SELECT DISTINCT replace(split_part(input_id, ':', 3), '-', ' ')
        FROM places WHERE input_id LIKE 'malqa:brandscan:%'
      """)

    MapSet.new(rows, fn [n] -> String.downcase(String.trim(to_string(n))) end)
  end

  @doc """
  Agreement between the address-derived district and the geometric box assignment.

  The boxes in `GmapsEx.Malqa.Districts` are hand-estimated. Twin-district affinity
  is 15 points of the Track A score, so if these two disagree often the boxes are
  wrong and that term is noise. Below ~85% agreement, fix the boxes before trusting
  the ranking.
  """
  @spec district_agreement(String.t()) :: map()
  def district_agreement(prefix \\ "malqa:%") do
    rows =
      Repo.all(
        from(p in "places",
          where: like(p.input_id, ^prefix) and not is_nil(p.latitude),
          select: %{
            lat: p.latitude,
            lon: p.longitude,
            address: p.address,
            complete_address: p.complete_address
          }
        ),
        timeout: :infinity
      )

    points = learn_points(prefix)

    # Leave-one-out: a labelled point must not vote for itself, or this measures
    # nothing at all.
    checked =
      rows
      |> Enum.map(fn r ->
        truth = Districts.from_address(r.complete_address, r.address)

        others =
          if truth,
            do: Enum.reject(points, fn {la, lo, _} -> la == r.lat and lo == r.lon end),
            else: points

        {truth, Districts.assign_knn(r.lat, r.lon, others)}
      end)
      |> Enum.reject(fn {from_addr, _} -> is_nil(from_addr) end)

    agree = Enum.count(checked, fn {a, b} -> a == b end)
    other = Enum.count(checked, fn {_a, b} -> b == "other" end)

    %{
      comparable: length(checked),
      agree: agree,
      agreement: pct(agree, length(checked)),
      total: length(rows),
      other_rate: pct(other, length(rows)),
      disagreements:
        checked
        |> Enum.reject(fn {a, b} -> a == b end)
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_k, n} -> -n end)
        |> Enum.take(12)
    }
  end

  @doc "Near-miss brand pairs — candidates for the explicit alias table."
  @spec alias_candidates(String.t(), float()) :: [map()]
  def alias_candidates(prefix \\ "malqa:%", threshold \\ 0.6) do
    sql = """
    SELECT a.brand_key, a.brand_name, b.brand_key, b.brand_name,
           round(similarity(a.brand_name, b.brand_name)::numeric, 2) AS sim
      FROM (SELECT DISTINCT brand_key, brand_name FROM places
             WHERE input_id LIKE $1 AND brand_name IS NOT NULL AND brand_name <> '') a
      JOIN (SELECT DISTINCT brand_key, brand_name FROM places
             WHERE input_id LIKE $1 AND brand_name IS NOT NULL AND brand_name <> '') b
        ON a.brand_key < b.brand_key
     WHERE similarity(a.brand_name, b.brand_name) > $2
     ORDER BY sim DESC
     LIMIT 80
    """

    %{rows: rows} = Repo.query!(sql, [prefix, threshold])

    Enum.map(rows, fn [ka, na, kb, nb, sim] ->
      %{key_a: ka, name_a: na, key_b: kb, name_b: nb, similarity: to_f(sim)}
    end)
  end

  defp pct(_, 0), do: 0.0
  defp pct(n, d), do: Float.round(n * 100 / d, 1)

  defp to_f(nil), do: nil
  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n) when is_number(n), do: n / 1
end
