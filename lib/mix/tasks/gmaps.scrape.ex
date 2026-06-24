defmodule Mix.Tasks.Gmaps.Scrape do
  @moduledoc """
  Scrape Google Maps from the CLI. One command, multiple queries, optional CSV.

  ## Examples

      # One query, one location, dump CSV when done
      mix gmaps.scrape \\
        --query "coffee shops" \\
        --geo "30.7834,30.9983" --gl eg --lang ar \\
        --csv out.csv --wait

      # Multiple queries against the same location (pass --query repeatedly)
      mix gmaps.scrape \\
        --query "مقاهي" --query "مطاعم" --query "هايبر ماركت" \\
        --geo "30.7834,30.9983" --zoom 14 --gl eg --lang ar \\
        --csv tanta.csv --wait

      # Grid-mode: divide a bbox into cells of N km, one search per cell × keyword
      mix gmaps.scrape \\
        --query "restaurants" \\
        --grid-bbox "37.7,-122.5,37.85,-122.35" --grid-cell-km 1.5 \\
        --gl us --csv sf-restaurants.csv --wait

  ## Switches

    * `--query`         Search term (repeat for multiple queries against the same location)
    * `--geo`           "lat,lon" — required unless `--grid-bbox` given
    * `--grid-bbox`     "minLat,minLon,maxLat,maxLon" — split into grid cells
    * `--grid-cell-km`  Cell size when using grid mode (default 1.0)
    * `--zoom`          Zoom level 11–15 (default 13). Lower = wider area.
    * `--lang`          Language code (default "en")
    * `--gl`            Country code (default "us") — important worldwide
    * `--csv`           File path to dump results when scrape finishes (implies --wait)
    * `--jsonl`         File path to dump results as JSONL (implies --wait)
    * `--wait`          Block until the run completes (default false; set true if --csv/--jsonl)
    * `--timeout`       Max wait seconds (default 1800 = 30 min)
  """

  use Mix.Task

  @shortdoc "Scrape Google Maps — one command, multi-query, CSV output"

  @switches [
    query: [:string, :keep],
    input: :string,
    geo: :string,
    zoom: :integer,
    grid_bbox: :string,
    grid_cell_km: :float,
    lang: :string,
    gl: :string,
    csv: :string,
    jsonl: :string,
    json: :string,
    wait: :boolean,
    timeout: :integer,
    search_concurrency: :integer,
    place_concurrency: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    cli_queries = Enum.map(Keyword.get_values(opts, :query), &{&1, nil})
    file_queries = load_input_file(opts[:input])
    queries = cli_queries ++ file_queries

    if queries == [] do
      Mix.raise(
        "Provide --query (repeatable) or --input path/to/queries.txt with one query per line"
      )
    end

    Mix.Task.run("app.start")

    # Dynamic Oban concurrency: scale per the CLI args for this run only.
    if sc = opts[:search_concurrency] do
      Oban.scale_queue(queue: :search, limit: sc)
      Mix.shell().info(":: search queue scaled to #{sc}")
    end

    if pc = opts[:place_concurrency] do
      Oban.scale_queue(queue: :place, limit: pc)
      Mix.shell().info(":: place queue scaled to #{pc}")
    end

    seeds = build_seeds(queries, opts)

    Mix.shell().info(
      ":: #{length(queries)} quer(y/ies) × #{length(seeds) |> div(length(queries))} location(s) = #{length(seeds)} seed job(s)"
    )

    Mix.shell().info(":: queries:  #{queries |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")

    {:ok, n} = GmapsEx.Runner.start(seeds)
    Mix.shell().info(":: enqueued #{n} jobs")

    wait? =
      opts[:wait] || opts[:csv] != nil || opts[:jsonl] != nil || opts[:json] != nil

    if wait? do
      timeout_s = opts[:timeout] || 1800
      attach_progress_logger()
      wait_for_completion(timeout_s)
      Mix.shell().info(":: scrape complete")
    end

    if path = opts[:csv], do: write_csv(path)
    if path = opts[:jsonl], do: write_jsonl(path)
    if path = opts[:json], do: write_json(path)
  end

  # Load one query per line from a file. Supports the Go scraper's `#!#`
  # syntax for custom input IDs — the suffix after `#!#` is propagated to
  # `place.input_id` for every place spawned by that query.
  #
  #     coffee shops near me #!#sf-batch-1
  defp load_input_file(nil), do: []

  defp load_input_file(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      case String.split(line, "#!#", parts: 2) do
        [q, id] -> {String.trim(q), String.trim(id)}
        [q] -> {q, nil}
      end
    end)
  end

  defp build_seeds(queries, opts) do
    lang = Keyword.get(opts, :lang, "en")
    gl = Keyword.get(opts, :gl, "us")
    zoom = Keyword.get(opts, :zoom, 13)

    locations =
      cond do
        bbox = Keyword.get(opts, :grid_bbox) ->
          parse_bbox(bbox) |> grid_locations(Keyword.get(opts, :grid_cell_km, 1.0))

        geo = Keyword.get(opts, :geo) ->
          [parse_geo(geo)]

        true ->
          Mix.raise(
            ~s|Provide either --geo "lat,lon" or --grid-bbox "minLat,minLon,maxLat,maxLon"|
          )
      end

    for {q, input_id} <- queries, {lat, lon} <- locations do
      %{query: q, input_id: input_id, lat: lat, lon: lon, zoom: zoom, lang: lang, gl: gl}
    end
  end

  defp grid_locations({min_lat, min_lon, max_lat, max_lon}, cell_km) do
    step_lat = cell_km / 110.574
    step_lon = cell_km / (111.320 * :math.cos((min_lat + max_lat) / 2 * :math.pi() / 180.0))

    for lat <- frange(min_lat, max_lat, step_lat),
        lon <- frange(min_lon, max_lon, step_lon) do
      {lat + step_lat / 2, lon + step_lon / 2}
    end
  end

  defp frange(start, stop, step) do
    Stream.unfold(start, fn v -> if v >= stop, do: nil, else: {v, v + step} end)
    |> Enum.to_list()
  end

  defp parse_geo(str) do
    [lat, lon] = String.split(str, ",", trim: true)
    {parse_float(String.trim(lat)), parse_float(String.trim(lon))}
  end

  defp parse_bbox(str) do
    [a, b, c, d] = String.split(str, ",", trim: true)
    {parse_float(a), parse_float(b), parse_float(c), parse_float(d)}
  end

  defp parse_float(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> Mix.raise("Bad number: #{s}")
    end
  end

  defp attach_progress_logger do
    :telemetry.attach_many(
      "gmaps-cli-progress",
      [
        [:gmaps_ex, :search, :ok],
        [:gmaps_ex, :place, :ok],
        [:gmaps_ex, :place, :error],
        [:gmaps_ex, :run, :complete]
      ],
      fn event, m, meta, _ ->
        case event do
          [:gmaps_ex, :search, :ok] ->
            Mix.shell().info(":: search ok '#{meta[:query]}' → #{m[:count]} places")

          [:gmaps_ex, :place, :ok] ->
            inline = m[:inline_reviews] || 0
            Mix.shell().info("   + #{meta[:title]} (#{inline} inline reviews)")

          [:gmaps_ex, :place, :error] ->
            Mix.shell().info("   ! place skipped: #{meta[:reason]}")

          [:gmaps_ex, :run, :complete] ->
            Mix.shell().info(":: run complete (#{m[:places]} places across #{m[:seeds]} seeds)")
        end
      end,
      nil
    )
  end

  defp wait_for_completion(timeout_s) do
    parent = self()

    :ok =
      :telemetry.attach(
        "gmaps-scrape-wait",
        [:gmaps_ex, :run, :complete],
        fn _, _, _, _ -> send(parent, :gmaps_done) end,
        nil
      )

    receive do
      :gmaps_done -> :ok
    after
      timeout_s * 1000 ->
        Mix.shell().error(":: timed out after #{timeout_s}s — partial results may still be in DB")
        :ok
    end
  end

  defp write_csv(path) do
    places = GmapsEx.Repo.all(GmapsEx.Place)
    GmapsEx.Output.Csv.write(places, path)

    Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(path)}")
  end

  defp write_jsonl(path) do
    places = GmapsEx.Repo.all(GmapsEx.Place)
    GmapsEx.Output.Jsonl.write(places, path)

    Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(path)}")
  end

  # Single-file JSON array (matches Go scraper's `-json` flag).
  defp write_json(path) do
    places = GmapsEx.Repo.all(GmapsEx.Place)
    body = places |> Enum.map(&GmapsEx.Place.to_attrs/1) |> Jason.encode!(pretty: true)
    File.write!(path, body)
    Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(path)}")
  end
end
