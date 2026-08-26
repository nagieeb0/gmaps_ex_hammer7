defmodule GmapsEx.Runner do
  @moduledoc """
  Top-level "kick off a scrape" entry point. Builds seed jobs from a list of
  queries × (geo|grid) and pushes them onto Oban.

  Equivalent to `runner/CreateSeedJobs` in the Go scraper.
  """

  alias GmapsEx.{Dedupe, Exiter}
  alias GmapsEx.Workers.SearchWorker

  @typedoc "A single seed location."
  @type seed :: %{
          required(:query) => String.t(),
          required(:lat) => float(),
          required(:lon) => float(),
          required(:zoom) => integer() | float(),
          optional(:lang) => String.t(),
          optional(:gl) => String.t(),
          optional(:tenant_id) => String.t()
        }

  @doc """
  Enqueue search jobs and start the run. Resets the per-run dedupe table and
  the exiter counters.
  """
  @spec start([seed()]) :: {:ok, non_neg_integer()}
  def start(seeds) when is_list(seeds) and seeds != [] do
    Dedupe.reset()
    Exiter.reset()
    Exiter.set_seed_count(length(seeds))

    jobs =
      Enum.map(seeds, fn seed ->
        SearchWorker.new(%{
          "query" => seed.query,
          "input_id" => Map.get(seed, :input_id),
          "lat" => seed.lat,
          "lon" => seed.lon,
          "zoom" => seed.zoom,
          "lang" => Map.get(seed, :lang, "en"),
          "gl" => Map.get(seed, :gl, "us"),
          "tenant_id" => Map.get(seed, :tenant_id),
          "extract_emails" => Map.get(seed, :extract_emails, false)
        })
      end)

    # Postgres caps a statement at 65,535 bind parameters and each job binds 9,
    # so one insert_all dies above ~7,200 seeds. A country-wide grid is well
    # past that. Chunk it.
    inserted =
      jobs
      |> Enum.chunk_every(2_000)
      |> Enum.flat_map(&Oban.insert_all/1)

    {:ok, length(inserted)}
  end

  @doc """
  Expand a (query, bbox, cell_km) into one seed per grid cell. Mirrors grid mode
  in `runner/grid.go`.
  """
  @spec grid_seeds(String.t(), {float(), float(), float(), float()}, float(), keyword()) :: [
          seed()
        ]
  def grid_seeds(query, {min_lat, min_lon, max_lat, max_lon}, cell_km, opts \\ []) do
    zoom = Keyword.get(opts, :zoom, 13)
    lang = Keyword.get(opts, :lang, "en")
    step_lat = km_to_lat_deg(cell_km)
    step_lon = km_to_lon_deg(cell_km, (min_lat + max_lat) / 2.0)

    gl = Keyword.get(opts, :gl, "us")

    for lat <- frange(min_lat, max_lat, step_lat),
        lon <- frange(min_lon, max_lon, step_lon) do
      %{
        query: query,
        lat: lat + step_lat / 2,
        lon: lon + step_lon / 2,
        zoom: zoom,
        lang: lang,
        gl: gl
      }
    end
  end

  defp km_to_lat_deg(km), do: km / 110.574
  defp km_to_lon_deg(km, lat), do: km / (111.320 * :math.cos(lat * :math.pi() / 180.0))

  defp frange(start, stop, step) do
    Stream.unfold(start, fn v ->
      if v >= stop, do: nil, else: {v, v + step}
    end)
    |> Enum.to_list()
  end
end
