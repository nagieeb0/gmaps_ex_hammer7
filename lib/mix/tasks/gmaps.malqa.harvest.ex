defmodule Mix.Tasks.Gmaps.Malqa.Harvest do
  @moduledoc """
  Staged Google Maps harvest for the Al Malqa white-space analysis.

      mix gmaps.malqa.harvest --stage site --dry-run
      mix gmaps.malqa.harvest --stage site,twins
      mix gmaps.malqa.harvest --stage kitchen
      mix gmaps.malqa.harvest --stage brandscan

  Runs **search-only by default** (`enrich: false`). `GmapsEx.Parser.Search` already
  fills title, categories, website, rating, review_count, address, lat/lon, phone and
  status straight from the search response, and brand grouping, geo math and scoring
  need nothing else. That turns one request per seed into one request per seed
  instead of one plus twenty — the difference between a four-hour harvest and a
  thirty-hour one on a single IP.

  Pass `--enrich` when you specifically want place-detail fields (menus, hours,
  owner), and `--emails` to additionally crawl each website for contact addresses.
  """

  use Mix.Task

  import Ecto.Query

  alias GmapsEx.Geo
  alias GmapsEx.Malqa.Districts

  @shortdoc "Staged F&B harvest for the Al Malqa site analysis"

  @site_lat 24.798
  @site_lon 46.595

  # 12 terms. Maps caps ~20 results per search, so many narrow terms beat a few
  # broad ones — the same lesson the catering task records.
  @fnb_queries [
    {"restaurants", "مطاعم"},
    {"cafe", "كافيه"},
    {"coffee", "قهوة مختصة"},
    {"burger", "مطعم برجر"},
    {"pizza", "مطعم بيتزا"},
    {"grill", "مطعم مشويات"},
    {"breakfast", "مطعم فطور"},
    {"sweets", "حلويات"},
    {"bakery", "مخبز"},
    {"shawarma", "شاورما"},
    {"restaurants-en", "restaurants"},
    {"cafe-en", "cafe"}
  ]

  # Track A2: the buyers of a production kitchen, not of a dining hall.
  @kitchen_queries [
    {"central-kitchen", "مطبخ مركزي"},
    {"cloud-kitchen", "مطبخ سحابي"},
    {"catering", "كاترينج"},
    {"catering-ar", "تموين غذائي"},
    {"iaasha", "إعاشة"},
    {"hospitality", "خدمات ضيافة"},
    {"buffet", "بوفيهات وولائم"},
    {"events-catering", "تجهيز حفلات"},
    {"wedding-hall", "قاعة أفراح"},
    {"prod-sweets", "مصنع حلويات"},
    {"prod-bakery", "مخبز إنتاج"},
    {"meal-prep", "وجبات جاهزة اشتراكات"},
    {"catering-en", "catering company"},
    {"cloud-kitchen-en", "cloud kitchen"},
    {"central-kitchen-en", "central kitchen"},
    {"food-service-en", "food service company"}
  ]

  # Only where an Egyptian brand that can fund Riyadh key money actually operates.
  @egypt_zones [
    {"new-cairo", 30.028, 31.492, 6.0, 6.0, 1.5},
    {"sheikh-zayed", 30.020, 30.970, 5.0, 5.0, 1.5},
    {"mohandeseen", 30.053, 31.205, 3.0, 3.0, 1.5},
    {"heliopolis", 30.088, 31.324, 3.5, 3.5, 1.5},
    {"maadi", 29.960, 31.258, 3.0, 3.0, 1.5},
    {"nasr-city", 30.056, 31.340, 4.0, 4.0, 1.5},
    {"alexandria", 31.230, 29.945, 5.0, 4.0, 1.5}
  ]

  # Saudi cities other than Riyadh. A brand trading strongly here but absent from
  # Riyadh is a brand with a proven format and an obvious next market — the segment
  # a Riyadh site is worth most to.
  @ksa_cities [
    {"jeddah", 21.543, 39.173, 14.0, 10.0, 2.5},
    {"makkah", 21.389, 39.857, 7.0, 7.0, 2.5},
    {"madinah", 24.470, 39.611, 7.0, 7.0, 2.5},
    {"dammam", 26.420, 50.089, 8.0, 7.0, 2.5},
    {"khobar", 26.279, 50.208, 7.0, 6.0, 2.5},
    {"qassim", 26.330, 43.975, 6.0, 6.0, 2.5},
    {"abha", 18.222, 42.505, 6.0, 6.0, 2.5},
    {"khamis", 18.306, 42.729, 5.0, 5.0, 2.5},
    {"taif", 21.270, 40.416, 5.0, 5.0, 2.5},
    {"tabuk", 28.383, 36.566, 5.0, 5.0, 2.5},
    {"hail", 27.516, 41.690, 4.0, 4.0, 2.5},
    {"jubail", 27.004, 49.658, 5.0, 5.0, 2.5},
    {"yanbu", 24.089, 38.063, 5.0, 5.0, 2.5},
    {"najran", 17.545, 44.223, 4.0, 4.0, 2.5},
    {"jazan", 16.889, 42.551, 4.0, 4.0, 2.5}
  ]

  # Riyadh bounding box for brand-name anchor scans.
  @riyadh_bbox {24.52, 46.48, 24.92, 46.90}

  @switches [
    stage: :string,
    site_lat: :float,
    site_lon: :float,
    radius_km: :float,
    cell_km: :float,
    anchors: :integer,
    enrich: :boolean,
    emails: :boolean,
    search_concurrency: :integer,
    place_concurrency: :integer,
    max_seeds: :integer,
    force: :boolean,
    timeout: :integer,
    dry_run: :boolean,
    brands_file: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    stages = (opts[:stage] || "site") |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    Mix.Task.run("app.start")

    seeds = Enum.flat_map(stages, &build_stage(&1, opts))
    max_seeds = opts[:max_seeds] || 15_000

    Mix.shell().info(":: stages #{Enum.join(stages, ",")} → #{length(seeds)} seed jobs")
    Mix.shell().info(":: est. #{estimate_minutes(length(seeds))} min at ~1.2 search req/s")

    cond do
      seeds == [] ->
        Mix.shell().error(":: no seeds built — check --stage")
        System.halt(1)

      length(seeds) > max_seeds and !opts[:force] ->
        Mix.shell().error(":: #{length(seeds)} seeds exceeds --max-seeds #{max_seeds}; pass --force")
        System.halt(1)

      opts[:dry_run] ->
        seeds
        |> Enum.group_by(& &1.input_id)
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.take(25)
        |> Enum.each(fn {k, v} -> Mix.shell().info("   #{k}: #{length(v)}") end)

        Mix.shell().info(":: dry-run — nothing enqueued")
        System.halt(0)

      true ->
        execute(seeds, opts)
    end
  end

  defp execute(seeds, opts) do
    sc = opts[:search_concurrency] || 6
    pc = opts[:place_concurrency] || 12
    Oban.scale_queue(queue: :search, limit: sc)
    Oban.scale_queue(queue: :place, limit: pc)
    if opts[:emails], do: Oban.scale_queue(queue: :emails, limit: 6)

    Mix.shell().info(":: concurrency search=#{sc} place=#{pc} enrich=#{!!opts[:enrich]}")

    {:ok, n} = GmapsEx.Runner.start(seeds)
    Mix.shell().info(":: enqueued #{n} jobs")

    attach_progress_logger()
    wait_for_completion(opts[:timeout] || 6 * 60 * 60)

    total = GmapsEx.Repo.one(from(p in "places", select: count(p.id)))
    Mix.shell().info(":: done — #{total} places in the database")
  end

  # ── stages ────────────────────────────────────────────────────────────

  defp build_stage("site", opts) do
    lat = opts[:site_lat] || @site_lat
    lon = opts[:site_lon] || @site_lon
    r = opts[:radius_km] || 3.0
    cell = opts[:cell_km] || 1.0

    for {la, lo} <- Geo.grid(lat, lon, r, r, cell),
        {tag, q} <- @fnb_queries do
      seed(q, la, lo, 15, "malqa:site:#{tag}", opts)
    end
  end

  defp build_stage("twins", opts) do
    cell = opts[:cell_km] || 1.5

    for tag <- Districts.twins(),
        {^tag, _ar, lat, lon, hlat, hlon, _p} <- Districts.all(),
        {la, lo} <- Geo.grid(lat, lon, hlon, hlat, cell),
        {qtag, q} <- @fnb_queries do
      seed(q, la, lo, 15, "malqa:twin:#{tag}:#{qtag}", opts)
    end
  end

  defp build_stage("kitchen", opts) do
    # City-wide but coarse: a caterer will take a kitchen anywhere in Riyadh, so
    # coverage matters more than density here.
    cell = opts[:cell_km] || 3.0
    {min_lat, min_lon, max_lat, max_lon} = @riyadh_bbox
    clat = (min_lat + max_lat) / 2
    clon = (min_lon + max_lon) / 2
    hh = (max_lat - min_lat) / 2 * 110.574
    hw = (max_lon - min_lon) / 2 * (111.320 * :math.cos(clat * :math.pi() / 180.0))

    for {la, lo} <- Geo.grid(clat, clon, hw, hh, cell),
        {tag, q} <- @kitchen_queries do
      seed(q, la, lo, 14, "malqa:kitchen:#{tag}", opts)
    end
  end

  defp build_stage("egypt", opts) do
    for {zone, lat, lon, hw, hh, cell} <- @egypt_zones,
        {la, lo} <- Geo.grid(lat, lon, hw, hh, opts[:cell_km] || cell),
        {tag, q} <- Enum.take(@fnb_queries, 10) do
      q
      |> seed(la, lo, 15, "malqa:eg:#{zone}:#{tag}", opts)
      |> Map.merge(%{gl: "eg", lang: "ar"})
    end
  end

  defp build_stage("ksa_cities", opts) do
    for {city, lat, lon, hw, hh, cell} <- @ksa_cities,
        {la, lo} <- Geo.grid(lat, lon, hw, hh, opts[:cell_km] || cell),
        {tag, q} <- @fnb_queries do
      seed(q, la, lo, 14, "malqa:ksa:#{city}:#{tag}", opts)
    end
  end

  defp build_stage("brandscan", opts) do
    brands = load_brands(opts[:brands_file] || "malqa/brandscan-queries.txt")
    anchors = Geo.anchors(@riyadh_bbox, opts[:anchors] || 9)

    for b <- brands, {la, lo} <- anchors do
      seed(b, la, lo, 12, "malqa:brandscan:#{slug(b)}", opts)
    end
  end

  defp build_stage("ksaprobe", opts) do
    brands = load_brands(opts[:brands_file] || "malqa/ksaprobe-queries.txt")
    # Riyadh + Jeddah + Dammam: if an Egyptian brand is in KSA at all, it is here.
    anchors =
      Geo.anchors(@riyadh_bbox, 6) ++
        [{21.54, 39.19}, {21.62, 39.15}, {26.42, 50.09}, {24.47, 39.61}]

    for b <- brands, {la, lo} <- anchors do
      seed(b, la, lo, 11, "malqa:ksaprobe:#{slug(b)}", opts)
    end
  end

  defp build_stage(unknown, _opts) do
    Mix.shell().error(":: unknown stage #{inspect(unknown)}")
    []
  end

  defp seed(query, lat, lon, zoom, input_id, opts) do
    %{
      query: query,
      lat: lat,
      lon: lon,
      zoom: zoom,
      lang: "ar",
      gl: "sa",
      input_id: input_id,
      enrich: !!opts[:enrich],
      extract_emails: !!opts[:emails]
    }
  end

  defp load_brands(path) do
    case File.read(path) do
      {:ok, body} ->
        body |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        Mix.shell().error(":: #{path} not found — run `mix gmaps.malqa.brands --emit-queries` first")
        []
    end
  end

  defp slug(s) do
    s
    |> String.replace(~r/\s+/u, "-")
    |> String.slice(0, 40)
  end

  defp estimate_minutes(n), do: Float.round(n / 1.2 / 60, 1)

  # ── run control ───────────────────────────────────────────────────────

  defp attach_progress_logger do
    :telemetry.attach_many(
      "malqa-progress",
      [[:gmaps_ex, :search, :ok], [:gmaps_ex, :run, :complete]],
      fn
        [:gmaps_ex, :search, :ok], m, meta, _ ->
          if :rand.uniform(60) == 1 do
            Mix.shell().info(":: '#{meta[:query]}' → #{m[:count]} places")
          end

        [:gmaps_ex, :run, :complete], m, _, _ ->
          Mix.shell().info(":: run complete (#{m[:places]} places)")
      end,
      nil
    )
  end

  # Polls oban_jobs rather than trusting the telemetry event alone: empty grid
  # cells are discarded without ever incrementing the exiter's counters.
  defp wait_for_completion(timeout_s) do
    parent = self()

    :telemetry.attach(
      "malqa-wait",
      [:gmaps_ex, :run, :complete],
      fn _, _, _, _ -> send(parent, :done) end,
      nil
    )

    poll_until_done(System.monotonic_time(:second) + timeout_s, 0)
  end

  defp poll_until_done(deadline, empty_polls) do
    receive do
      :done -> :ok
    after
      30_000 ->
        cond do
          System.monotonic_time(:second) >= deadline ->
            Mix.shell().info(":: timeout — partial results in the database")
            :ok

          empty_polls + 1 >= 2 and pending_jobs() == 0 ->
            :ok

          pending_jobs() == 0 ->
            poll_until_done(deadline, empty_polls + 1)

          true ->
            poll_until_done(deadline, 0)
        end
    end
  end

  defp pending_jobs do
    GmapsEx.Repo.one(
      from(j in "oban_jobs",
        where: j.state in ["available", "executing", "scheduled", "retryable"],
        select: count(j.id)
      )
    )
  end
end
