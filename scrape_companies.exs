# Scrape additional FM / O&M / HVAC / defense / water companies in
# Jeddah + Riyadh via GmapsEx.search/2 (no DB, no Oban).
#
# Usage:
#   mix run --no-start scrape_companies.exs            # live run
#   mix run --no-start scrape_companies.exs test       # single validation search

queries = [
  # Facilities management / operations & maintenance
  "facilities management company",
  "operation and maintenance company",
  "FM company",
  "building maintenance company",
  # Mechanical / HVAC
  "HVAC company",
  "mechanical engineering company",
  "air conditioning maintenance company",
  "central cooling company",
  # Healthcare FM
  "hospital maintenance company",
  # Defense / military support
  "defense support services company",
  # Water / wastewater
  "water treatment company",
  "wastewater treatment company",
  "desalination company"
]

# Jeddah and Riyadh center points (lat, lon)
geos = [
  {"Jeddah", 21.4858, 39.1925},
  {"Riyadh", 24.7136, 46.6753}
]

gl = "sa"
lang = "en"
zoom = 12

# Start only the GenServers search/2 depends on (no Repo/Oban).
# Req.Finch pool registry must be up or HTTP requests crash.
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = GmapsEx.Http.ProxyPool.start_link([])
{:ok, _} = GmapsEx.Http.SessionStore.start_link([])

IO.puts("Warming Google session for gl=#{gl} ...")
GmapsEx.Http.SessionStore.warm("default", lang: lang, gl: gl)
Process.sleep(500)

defmodule Runner do
  def run_one(query, _geo_name, lat, lon, gl, lang, zoom) do
    case GmapsEx.search(query, lat: lat, lon: lon, zoom: zoom, gl: gl, lang: lang) do
      {:ok, places} ->
        rows =
          Enum.map(places, fn p ->
            %{
              title: p.title,
              category: List.first(p.categories),
              rating: p.review_rating,
              reviews: p.review_count,
              address: p.address,
              phone: p.phone,
              website: p.website,
              data_id: p.data_id
            }
          end)

        {:ok, rows}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

if System.get_env("ARGS_TEST") == "1" or (Enum.at(System.argv(), 0) == "test") do
  IO.puts("=== VALIDATION SEARCH ===")
  {:ok, rows} = Runner.run_one("facilities management company", "Jeddah", 21.4858, 39.1925, gl, lang, zoom)
  IO.inspect(rows, label: "jeddah_fm", limit: :infinity)
  IO.puts("=== END VALIDATION ===")
else
  # Stream each query's results to a file incrementally so a crash can't lose
# everything. We keep the accumulator too, but the file is the source of truth.
File.write!("scrape_raw_results.jsonl", "")

all =
    for {geo_name, lat, lon} <- geos, query <- queries, reduce: %{} do
      acc ->
        key = "#{geo_name}|#{query}"
        IO.puts("Searching: #{key}")
        rows =
          try do
            case Runner.run_one(query, geo_name, lat, lon, gl, lang, zoom) do
              {:ok, r} ->
                IO.puts("  -> #{length(r)} places")
                r
              {:error, reason} ->
                IO.puts("  -> ERROR #{inspect(reason)}")
                {:error, reason}
            end
          rescue
            e ->
              IO.puts("  -> EXCEPTION #{Exception.message(e)}")
              {:error, {:exception, Exception.message(e)}}
          end

        # Append this query's result to the JSONL log.
        serializable =
          case rows do
            list when is_list(list) -> list
            other -> %{error: inspect(other)}
          end

        File.write!("scrape_raw_results.jsonl",
          Jason.encode!(%{key: key, rows: serializable, ok: is_list(rows)}) <> "\n", [:append])

        Process.sleep(800)
        Map.put(acc, key, rows)
    end

  serializable_all =
    Enum.map(all, fn {k, v} ->
      {k, if(is_list(v), do: v, else: %{error: inspect(v)})}
    end)
    |> Map.new()

  File.write!("scrape_raw_results.json", Jason.encode!(serializable_all, pretty: true))
  total = all |> Map.values() |> Enum.flat_map(fn
    list when is_list(list) -> list
    _ -> []
  end) |> length()
  IO.puts("Wrote scrape_raw_results.json (#{total} total place records)")
end
