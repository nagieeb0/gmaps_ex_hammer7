defmodule Mix.Tasks.Gmaps.Egypt do
  @moduledoc """
  Egypt-wide dental clinic scrape.

  Population-centered grids around every governorate capital + major town +
  resort city + Western Desert oasis. Skips empty Sahara.

  ## Usage

      mix gmaps.egypt --csv egypt-dentists.csv

  Add `--dry-run` to see the cell count without enqueueing.

  ## Scale

  Default config: ~1,000 cells × 4 query variants = ~4,000 search jobs.
  Expected wall clock: 30–90 min single IP. With proxies: ~10–20 min.

  Each scraped place is tagged with `input_id = "egypt-dentists:<city>"` —
  filter by region post-hoc with `WHERE input_id LIKE 'egypt-dentists:cairo%'`.
  """

  use Mix.Task

  @shortdoc "Scrape every dentist & dental clinic across Egypt"

  # 4 queries — Arabic doctor/clinic/center + English. Google's category
  # matching covers the rest (طبيب أسنان maps to the same places as دكتور أسنان).
  @queries [
    "دكتور أسنان",
    "عيادة أسنان",
    "مركز أسنان",
    "dental clinic"
  ]

  # Egypt's actual population centers. Each: {tag, lat, lon, half_width_km,
  # half_height_km, cell_km}. Centered on the city, sized to cover the urban
  # footprint plus margin.
  @cities [
    # Greater Cairo — the megacity. Covers Cairo proper + Giza + Helwan +
    # 6 October + New Cairo + Shubra + Maadi + Heliopolis.
    {"cairo", 30.04, 31.25, 18.0, 18.0, 1.5},

    # Alexandria + Mediterranean coast
    {"alexandria", 31.20, 29.92, 12.0, 6.0, 1.5},

    # Nile Delta — every major city gets its own focused grid
    {"tanta", 30.78, 31.00, 4.0, 4.0, 1.5},
    {"mansoura", 31.04, 31.38, 5.0, 4.0, 1.5},
    {"zagazig", 30.59, 31.50, 4.0, 4.0, 1.5},
    {"mahalla", 30.97, 31.17, 4.0, 4.0, 1.5},
    {"damanhour", 31.03, 30.47, 4.0, 4.0, 1.5},
    {"kafr-el-sheikh", 31.11, 30.94, 3.0, 3.0, 1.5},
    {"damietta", 31.42, 31.81, 4.0, 4.0, 1.5},
    {"banha", 30.46, 31.18, 3.0, 3.0, 1.5},
    {"shibin-el-kom", 30.55, 31.01, 3.0, 3.0, 1.5},

    # Suez Canal
    {"port-said", 31.27, 32.30, 5.0, 5.0, 1.5},
    {"ismailia", 30.59, 32.27, 5.0, 5.0, 1.5},
    {"suez", 29.97, 32.55, 5.0, 4.0, 1.5},

    # Middle / Upper Egypt — Nile Valley
    {"fayoum", 29.31, 30.84, 5.0, 5.0, 1.5},
    {"beni-suef", 29.07, 31.08, 4.0, 4.0, 1.5},
    {"minya", 28.11, 30.75, 4.0, 4.0, 1.5},
    {"asyut", 27.18, 31.18, 5.0, 5.0, 1.5},
    {"sohag", 26.56, 31.69, 4.0, 4.0, 1.5},
    {"qena", 26.16, 32.72, 4.0, 4.0, 1.5},
    {"luxor", 25.69, 32.64, 5.0, 5.0, 1.5},
    {"aswan", 24.09, 32.90, 5.0, 5.0, 1.5},

    # Red Sea resort cities
    {"hurghada", 27.26, 33.81, 10.0, 5.0, 2.0},
    {"el-gouna", 27.39, 33.68, 3.0, 3.0, 2.0},
    {"safaga", 26.74, 33.94, 3.0, 3.0, 2.0},
    {"marsa-alam", 25.07, 34.89, 3.0, 3.0, 2.0},

    # Sinai resort + administrative cities
    {"sharm-el-sheikh", 27.92, 34.33, 6.0, 6.0, 2.0},
    {"dahab", 28.49, 34.51, 3.0, 3.0, 2.0},
    {"nuweiba", 29.04, 34.66, 2.0, 2.0, 2.0},
    {"taba", 29.49, 34.89, 2.0, 2.0, 2.0},
    {"el-tor", 28.24, 33.62, 3.0, 3.0, 2.0},
    {"el-arish", 31.13, 33.80, 4.0, 4.0, 2.0},

    # Mediterranean western coast
    {"marsa-matrouh", 31.35, 27.24, 5.0, 5.0, 2.0},

    # Western Desert oases
    {"siwa", 29.20, 25.52, 3.0, 3.0, 2.0},
    {"bahariya", 28.35, 28.85, 2.0, 2.0, 2.0},
    {"farafra", 27.07, 27.97, 2.0, 2.0, 2.0},
    {"dakhla", 25.50, 29.00, 3.0, 3.0, 2.0},
    {"kharga", 25.45, 30.55, 3.0, 3.0, 2.0}
  ]

  @switches [
    csv: :string,
    jsonl: :string,
    dry_run: :boolean,
    timeout: :integer,
    search_concurrency: :integer,
    place_concurrency: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    seeds = build_seeds()
    n_cells = div(length(seeds), length(@queries))

    Mix.shell().info(
      ":: Egypt dental sweep: #{length(@queries)} queries × #{n_cells} cells × #{length(@cities)} regions = #{length(seeds)} seed jobs"
    )

    Mix.shell().info(
      ":: regions: #{@cities |> Enum.map(&elem(&1, 0)) |> Enum.take(10) |> Enum.join(", ")}, …"
    )

    if opts[:dry_run] do
      Mix.shell().info(":: dry-run — not enqueueing")
      System.halt(0)
    end

    Mix.Task.run("app.start")

    sc = opts[:search_concurrency] || 15
    pc = opts[:place_concurrency] || 25
    Oban.scale_queue(queue: :search, limit: sc)
    Oban.scale_queue(queue: :place, limit: pc)
    Mix.shell().info(":: concurrency search=#{sc} place=#{pc}")

    {:ok, n} = GmapsEx.Runner.start(seeds)
    Mix.shell().info(":: enqueued #{n} jobs")

    timeout_s = opts[:timeout] || 4 * 60 * 60
    attach_progress_logger()
    wait_for_completion(timeout_s)

    if path = opts[:csv] || "egypt-dentists.csv" do
      places = GmapsEx.Repo.all(GmapsEx.Place)
      GmapsEx.Output.Csv.write(places, path)
      Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(path)}")
    end

    if path = opts[:jsonl] do
      places = GmapsEx.Repo.all(GmapsEx.Place)
      GmapsEx.Output.Jsonl.write(places, path)
      Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(path)}")
    end
  end

  defp build_seeds do
    for {tag, lat, lon, hw_km, hh_km, cell_km} <- @cities,
        {lat_c, lon_c} <- grid(lat, lon, hw_km, hh_km, cell_km),
        q <- @queries do
      %{
        query: q,
        input_id: "egypt-dentists:#{tag}",
        lat: lat_c,
        lon: lon_c,
        zoom: 14,
        lang: "ar",
        gl: "eg"
      }
    end
  end

  # Build a grid around (lat, lon) extending ±hw_km East/West and ±hh_km N/S,
  # stepping by cell_km. Cells are *centered* on grid points.
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

  defp attach_progress_logger do
    :telemetry.attach_many(
      "gmaps-egypt-progress",
      [
        [:gmaps_ex, :search, :ok],
        [:gmaps_ex, :place, :ok],
        [:gmaps_ex, :run, :complete]
      ],
      fn event, m, meta, _ ->
        case event do
          [:gmaps_ex, :search, :ok] ->
            if Enum.random(1..50) == 1 do
              Mix.shell().info(":: search '#{meta[:query]}' → #{m[:count]} places")
            end

          [:gmaps_ex, :place, :ok] ->
            :ok

          [:gmaps_ex, :run, :complete] ->
            Mix.shell().info(":: run complete (#{m[:places]} places)")
        end
      end,
      nil
    )
  end

  defp wait_for_completion(timeout_s) do
    parent = self()

    :ok =
      :telemetry.attach(
        "gmaps-egypt-wait",
        [:gmaps_ex, :run, :complete],
        fn _, _, _, _ -> send(parent, :done) end,
        nil
      )

    receive do
      :done -> :ok
    after
      timeout_s * 1000 ->
        Mix.shell().info(":: timeout — partial results in DB")
        :ok
    end
  end
end
