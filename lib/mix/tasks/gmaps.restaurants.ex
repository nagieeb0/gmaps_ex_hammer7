defmodule Mix.Tasks.Gmaps.Restaurants do
  @moduledoc """
  Scrape all restaurants in المنصورة (Mansoura) & شبين الكوم (Shebin El Kom).

  **WARNING**: This task deletes ALL existing places, reviews, and completed
  Oban jobs before starting the scrape. Only run when you've already exported
  the old data.

  ## Usage

      mix gmaps.restaurants

  Options:

      --dry-run              Show seed count without scraping
      --timeout N            Max seconds to wait (default 4 hours)
      --search-concurrency N Override search queue concurrency (default 15)
      --place-concurrency N  Override place queue concurrency (default 25)
      --skip-purge           Don't delete old data before scraping

  ## Output

  Two CSV files per city are written on completion:

      mansoura-restaurants.csv
      shebin-restaurants.csv
  """

  use Mix.Task

  import Ecto.Query

  @shortdoc "Scrape restaurants in المنصورة & شبين الكوم (purges old data first)"

  # ─── Search queries ──────────────────────────────────────────────────
  # Broad Arabic + English queries to cover every possible restaurant type.
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
  # {tag, center_lat, center_lon, half_width_km, half_height_km, cell_km}
  #
  # المنصورة — larger urban sprawl including ميت غمر satellite areas
  # شبين الكوم — compact urban center, smaller grid
  @cities [
    {"mansoura", 31.04, 31.38, 6.0, 5.0, 1.0},
    {"shebin-el-kom", 30.55, 31.01, 4.0, 4.0, 1.0}
  ]

  @switches [
    dry_run: :boolean,
    timeout: :integer,
    search_concurrency: :integer,
    place_concurrency: :integer,
    skip_purge: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    seeds = build_seeds()
    n_cells = div(length(seeds), length(@queries))

    Mix.shell().info("""
    ╔══════════════════════════════════════════════════════════════╗
    ║  🍽️  Restaurant Scraper — المنصورة & شبين الكوم              ║
    ╠══════════════════════════════════════════════════════════════╣
    ║  Queries:    #{length(@queries) |> to_string() |> String.pad_trailing(44)}║
    ║  Grid cells: #{n_cells |> to_string() |> String.pad_trailing(44)}║
    ║  Seed jobs:  #{length(seeds) |> to_string() |> String.pad_trailing(44)}║
    ║  Cities:     المنصورة, شبين الكوم#{String.duplicate(" ", 27)}║
    ╚══════════════════════════════════════════════════════════════╝
    """)

    if opts[:dry_run] do
      Mix.shell().info(":: dry-run — not enqueueing. #{length(seeds)} jobs would be created.")

      for {tag, _, _, _, _, _} <- @cities do
        city_seeds = Enum.count(seeds, &(String.contains?(&1.input_id, tag)))
        Mix.shell().info("   #{tag}: #{city_seeds} seeds")
      end

      System.halt(0)
    end

    Mix.Task.run("app.start")

    # ── Step 1: Purge old data ──────────────────────────────────────────
    unless opts[:skip_purge] do
      purge_old_data()
    end

    # ── Step 2: Scale queues ────────────────────────────────────────────
    sc = opts[:search_concurrency] || 15
    pc = opts[:place_concurrency] || 25
    Oban.scale_queue(queue: :search, limit: sc)
    Oban.scale_queue(queue: :place, limit: pc)
    Mix.shell().info(":: concurrency search=#{sc} place=#{pc}")

    # ── Step 3: Enqueue ─────────────────────────────────────────────────
    {:ok, n} = GmapsEx.Runner.start(seeds)
    Mix.shell().info(":: enqueued #{n} jobs — scraping started")

    # ── Step 4: Wait ────────────────────────────────────────────────────
    timeout_s = opts[:timeout] || 4 * 60 * 60
    attach_progress_logger()
    wait_for_completion(timeout_s)

    # ── Step 5: Export per-city CSVs ────────────────────────────────────
    export_per_city()
  end

  # ─── Purge ────────────────────────────────────────────────────────────
  defp purge_old_data do
    Mix.shell().info(":: 🗑️  Purging old data …")

    # Use raw SQL TRUNCATE CASCADE — orders of magnitude faster than
    # Ecto delete_all on tables with 400K+ rows, and avoids connection
    # timeouts that killed the previous approach.
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
    Mix.shell().info(":: ✅ Database cleaned — ready for fresh scrape")
  end

  # ─── Seed builder ────────────────────────────────────────────────────
  defp build_seeds do
    for {tag, lat, lon, hw_km, hh_km, cell_km} <- @cities,
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

  # ─── Export ──────────────────────────────────────────────────────────
  defp export_per_city do
    Mix.shell().info(":: 📦 Exporting results …")

    all_places = GmapsEx.Repo.all(GmapsEx.Place)
    Mix.shell().info(":: total places in DB: #{length(all_places)}")

    # Mansoura
    mansoura =
      Enum.filter(all_places, fn p ->
        (p.input_id || "") |> String.contains?("mansoura")
      end)

    if mansoura != [] do
      GmapsEx.Output.Csv.write(mansoura, "mansoura-restaurants.csv")
      Mix.shell().info(":: ✅ mansoura-restaurants.csv — #{length(mansoura)} places")
    end

    # Shebin El Kom
    shebin =
      Enum.filter(all_places, fn p ->
        (p.input_id || "") |> String.contains?("shebin")
      end)

    if shebin != [] do
      GmapsEx.Output.Csv.write(shebin, "shebin-restaurants.csv")
      Mix.shell().info(":: ✅ shebin-restaurants.csv — #{length(shebin)} places")
    end

    # Combined
    combined = mansoura ++ shebin

    if combined != [] do
      GmapsEx.Output.Csv.write(combined, "delta-restaurants.csv")
      Mix.shell().info(":: ✅ delta-restaurants.csv — #{length(combined)} places (combined)")
    end
  end

  # ─── Progress logging ───────────────────────────────────────────────
  defp attach_progress_logger do
    :telemetry.attach_many(
      "gmaps-restaurants-progress",
      [
        [:gmaps_ex, :search, :ok],
        [:gmaps_ex, :place, :ok],
        [:gmaps_ex, :place, :error],
        [:gmaps_ex, :run, :complete]
      ],
      fn event, m, meta, _ ->
        case event do
          [:gmaps_ex, :search, :ok] ->
            # Log every 10th search to avoid flooding
            if Enum.random(1..10) == 1 do
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
        "gmaps-restaurants-wait",
        [:gmaps_ex, :run, :complete],
        fn _, _, _, _ -> send(parent, :restaurants_done) end,
        nil
      )

    receive do
      :restaurants_done -> :ok
    after
      timeout_s * 1000 ->
        Mix.shell().info(":: ⏰ timeout after #{timeout_s}s — exporting partial results")
        :ok
    end
  end
end
