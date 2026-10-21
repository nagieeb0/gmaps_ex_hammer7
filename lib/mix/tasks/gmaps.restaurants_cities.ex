defmodule Mix.Tasks.Gmaps.RestaurantsCities do
  @moduledoc """
  Scrape all restaurants across major Egyptian cities.

  Cities: القاهرة، الجيزة، الإسكندرية، الإسماعيلية، السويس،
          كفر الشيخ، دمنهور، الزقازيق

  ## Usage

      mix gmaps.restaurants_cities

  Options:

      --dry-run              Show seed count without scraping
      --timeout N            Max seconds to wait (default 6 hours)
      --search-concurrency N Override search queue concurrency (default 15)
      --place-concurrency N  Override place queue concurrency (default 25)
      --skip-purge           Don't delete old data before scraping (default)
      --purge                Delete ALL existing data before scraping

  ## Output

  One CSV per city + combined file:

      cairo-restaurants.csv
      giza-restaurants.csv
      alexandria-restaurants.csv
      ismailia-restaurants.csv
      suez-restaurants.csv
      kafr-el-sheikh-restaurants.csv
      damanhour-restaurants.csv
      zagazig-restaurants.csv
      all-cities-restaurants.csv
  """

  use Mix.Task

  @shortdoc "Scrape restaurants in Cairo, Giza, Alex, Ismailia, Suez, Kafr El Sheikh, Damanhour, Zagazig"

  # ─── Search queries ──────────────────────────────────────────────────
  @queries [
    "مطاعم",
    "مطعم",
    "restaurants",
    "restaurant",
    "مطاعم فول وطعمية",
    "مطاعم شاورما",
    "مطاعم بيتزا",
    "مطاعم مشويات",
    "مطاعم فراخ",
    "مطاعم أسماك",
    "كشري",
    "مطاعم سوري",
    "fast food",
    "مطاعم وجبات سريعة",
    "كافيهات ومطاعم",
    "بيتزا",
    "فطاطري"
  ]

  # ─── City grids ──────────────────────────────────────────────────────
  # {tag, display_name, center_lat, center_lon, half_width_km, half_height_km, cell_km}
  @cities [
    # القاهرة — Greater Cairo: Cairo proper + Helwan + New Cairo + Shubra +
    # Maadi + Heliopolis + Nasr City + 10th of Ramadan satellite
    {"cairo", "القاهرة", 30.06, 31.25, 16.0, 14.0, 1.5},

    # الجيزة — Giza: Dokki, Mohandeseen, Haram, Faisal, 6 October, Sheikh Zayed
    {"giza", "الجيزة", 30.01, 31.13, 14.0, 10.0, 1.5},

    # الإسكندرية — Alexandria + Mediterranean coast strip
    {"alexandria", "الإسكندرية", 31.20, 29.92, 12.0, 5.0, 1.5},

    # الإسماعيلية
    {"ismailia", "الإسماعيلية", 30.59, 32.27, 5.0, 5.0, 1.5},

    # السويس
    {"suez", "السويس", 29.97, 32.55, 5.0, 4.0, 1.5},

    # كفر الشيخ
    {"kafr-el-sheikh", "كفر الشيخ", 31.11, 30.94, 4.0, 4.0, 1.5},

    # دمنهور
    {"damanhour", "دمنهور", 31.03, 30.47, 4.0, 4.0, 1.5},

    # الزقازيق
    {"zagazig", "الزقازيق", 30.59, 31.50, 5.0, 5.0, 1.5}
  ]

  @switches [
    dry_run: :boolean,
    timeout: :integer,
    search_concurrency: :integer,
    place_concurrency: :integer,
    skip_purge: :boolean,
    purge: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    seeds = build_seeds()
    n_cells = div(length(seeds), length(@queries))

    city_list = @cities |> Enum.map(&elem(&1, 1)) |> Enum.join("، ")

    Mix.shell().info("""
    ╔══════════════════════════════════════════════════════════════════╗
    ║  🍽️  Restaurant Scraper — Egyptian Cities                       ║
    ╠══════════════════════════════════════════════════════════════════╣
    ║  Queries:    #{length(@queries) |> to_string() |> String.pad_trailing(48)}║
    ║  Grid cells: #{n_cells |> to_string() |> String.pad_trailing(48)}║
    ║  Seed jobs:  #{length(seeds) |> to_string() |> String.pad_trailing(48)}║
    ╚══════════════════════════════════════════════════════════════════╝
    """)

    Mix.shell().info(":: Cities: #{city_list}\n")

    for {tag, name, _, _, _, _, _} <- @cities do
      city_seeds = Enum.count(seeds, &String.contains?(&1.input_id, tag))
      Mix.shell().info("   #{name} (#{tag}): #{city_seeds} seeds")
    end

    Mix.shell().info("")

    if opts[:dry_run] do
      Mix.shell().info(":: dry-run — not enqueueing")
      System.halt(0)
    end

    Mix.Task.run("app.start")

    # ── Step 1: Purge (only if --purge explicitly passed) ───────────
    if opts[:purge] do
      purge_old_data()
    else
      Mix.shell().info(":: skipping purge (pass --purge to wipe DB first)")
    end

    # ── Step 2: Scale queues ────────────────────────────────────────
    sc = opts[:search_concurrency] || 15
    pc = opts[:place_concurrency] || 25
    Oban.scale_queue(queue: :search, limit: sc)
    Oban.scale_queue(queue: :place, limit: pc)
    Mix.shell().info(":: concurrency search=#{sc} place=#{pc}")

    # ── Step 3: Enqueue ─────────────────────────────────────────────
    {:ok, n} = GmapsEx.Runner.start(seeds)
    Mix.shell().info(":: enqueued #{n} jobs — scraping started 🚀")

    # ── Step 4: Wait ────────────────────────────────────────────────
    timeout_s = opts[:timeout] || 6 * 60 * 60
    attach_progress_logger()
    wait_for_completion(timeout_s)

    # ── Step 5: Export per-city CSVs ────────────────────────────────
    export_per_city()
  end

  # ─── Purge ────────────────────────────────────────────────────────
  defp purge_old_data do
    Mix.shell().info(":: 🗑️  Purging old data …")

    Ecto.Adapters.SQL.query!(
      GmapsEx.Repo,
      "TRUNCATE places CASCADE",
      [],
      timeout: 120_000
    )

    Mix.shell().info("   truncated places + reviews (CASCADE)")

    Ecto.Adapters.SQL.query!(
      GmapsEx.Repo,
      "TRUNCATE oban_jobs",
      [],
      timeout: 60_000
    )

    Mix.shell().info("   truncated oban_jobs")
    Mix.shell().info(":: ✅ Database cleaned")
  end

  # ─── Seed builder ────────────────────────────────────────────────
  defp build_seeds do
    for {tag, _name, lat, lon, hw_km, hh_km, cell_km} <- @cities,
        {lat_c, lon_c} <- grid(lat, lon, hw_km, hh_km, cell_km),
        q <- @queries do
      %{
        query: q,
        input_id: "restaurants:#{tag}",
        lat: lat_c,
        lon: lon_c,
        zoom: 15,
        lang: "ar",
        gl: "eg"
      }
    end
  end

  defp grid(lat, lon, hw_km, hh_km, cell_km) do
    step_lat = cell_km / 110.574
    step_lon = cell_km / (111.320 * :math.cos(lat * :math.pi() / 180.0))
    half_lat = hh_km / 110.574
    half_lon = hw_km / (111.320 * :math.cos(lat * :math.pi() / 180.0))

    for la <- frange(lat - half_lat, lat + half_lat, step_lat),
        lo <- frange(lon - half_lon, lon + half_lon, step_lon) do
      {la, lo}
    end
  end

  defp frange(start, stop, step) do
    Stream.unfold(start, fn v -> if v > stop, do: nil, else: {v, v + step} end)
    |> Enum.to_list()
  end

  # ─── Export ──────────────────────────────────────────────────────
  defp export_per_city do
    Mix.shell().info(":: 📦 Exporting results …")

    all_places = GmapsEx.Repo.all(GmapsEx.Place)
    Mix.shell().info(":: total places in DB: #{length(all_places)}")

    # Export each city
    for {tag, name, _, _, _, _, _} <- @cities do
      city_places =
        Enum.filter(all_places, fn p ->
          (p.input_id || "") == "restaurants:#{tag}"
        end)

      if city_places != [] do
        path = "#{tag}-restaurants.csv"
        GmapsEx.Output.Csv.write(city_places, path)
        Mix.shell().info(":: ✅ #{path} — #{length(city_places)} places (#{name})")
      else
        Mix.shell().info(":: ⚠️  #{tag}: no places found")
      end
    end

    # Combined file for all cities in this batch
    batch_places =
      Enum.filter(all_places, fn p ->
        id = p.input_id || ""

        Enum.any?(@cities, fn {tag, _, _, _, _, _, _} ->
          id == "restaurants:#{tag}"
        end)
      end)

    if batch_places != [] do
      GmapsEx.Output.Csv.write(batch_places, "all-cities-restaurants.csv")

      Mix.shell().info(
        ":: ✅ all-cities-restaurants.csv — #{length(batch_places)} places (combined)"
      )
    end
  end

  # ─── Progress logging ───────────────────────────────────────────
  defp attach_progress_logger do
    :telemetry.attach_many(
      "gmaps-cities-progress",
      [
        [:gmaps_ex, :search, :ok],
        [:gmaps_ex, :place, :ok],
        [:gmaps_ex, :place, :error],
        [:gmaps_ex, :run, :complete]
      ],
      fn event, m, meta, _ ->
        case event do
          [:gmaps_ex, :search, :ok] ->
            if Enum.random(1..20) == 1 do
              Mix.shell().info(":: search '#{meta[:query]}' → #{m[:count]} places")
            end

          [:gmaps_ex, :place, :ok] ->
            :ok

          [:gmaps_ex, :place, :error] ->
            Mix.shell().info("   ! place error: #{meta[:reason]}")

          [:gmaps_ex, :run, :complete] ->
            Mix.shell().info(
              ":: 🎉 run complete! #{m[:places]} places across #{m[:seeds]} seeds"
            )
        end
      end,
      nil
    )
  end

  defp wait_for_completion(timeout_s) do
    parent = self()

    :ok =
      :telemetry.attach(
        "gmaps-cities-wait",
        [:gmaps_ex, :run, :complete],
        fn _, _, _, _ -> send(parent, :cities_done) end,
        nil
      )

    receive do
      :cities_done -> :ok
    after
      timeout_s * 1000 ->
        Mix.shell().info(":: ⏰ timeout after #{timeout_s}s — exporting partial results")
        :ok
    end
  end
end
