# Riyadh event-industry sweep: enqueue grid × queries, then drain in the SAME
# BEAM node so the in-memory Dedupe survives and no job is orphaned.
# ponytail: one script instead of scrape+drain+export tasks — the CLI's --wait
# returns before place enrichment runs.
import Ecto.Query
alias GmapsEx.Repo

bbox = {24.50, 46.50, 25.02, 46.95}
cell_km = String.to_float(System.get_env("CELL_KM") || "5.0")
{min_lat, min_lon, max_lat, max_lon} = bbox

step_lat = cell_km / 110.574
step_lon = cell_km / (111.320 * :math.cos((min_lat + max_lat) / 2 * :math.pi() / 180.0))
frange = fn a, b, s -> Stream.unfold(a, &if(&1 >= b, do: nil, else: {&1, &1 + s})) |> Enum.to_list() end

cells =
  for lat <- frange.(min_lat, max_lat, step_lat),
      lon <- frange.(min_lon, max_lon, step_lon),
      do: {lat + step_lat / 2, lon + step_lon / 2}

queries =
  "/home/nagieeb/Plstka/riyadh-events/queries.txt"
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  |> Enum.map(fn l -> [q, id] = String.split(l, "#!#", parts: 2); {String.trim(q), String.trim(id)} end)

seeds =
  for {q, tag} <- queries, {lat, lon} <- cells do
    %{query: q, input_id: tag, lat: lat, lon: lon, zoom: 13, lang: "ar", gl: "sa"}
  end

IO.puts(":: #{length(queries)} queries × #{length(cells)} cells = #{length(seeds)} seeds")
{:ok, n} = GmapsEx.Runner.start(seeds)
IO.puts(":: enqueued #{n}")

deadline = String.to_integer(System.get_env("DEADLINE") || "21600")
t0 = System.monotonic_time(:second)
pending = ["available", "executing", "scheduled", "retryable"]

loop = fn loop ->
  Process.sleep(30_000)
  n = Repo.one(from j in "oban_jobs", where: j.state in ^pending, select: count())
  disc = Repo.one(from j in "oban_jobs", where: j.state == "discarded", select: count())
  places = Repo.one(from p in "places", select: count())
  enr = Repo.one(from p in "places", where: not is_nil(p.category), select: count())
  el = System.monotonic_time(:second) - t0
  IO.puts("[#{div(el, 60)}m] pending=#{n} discarded=#{disc} places=#{places} enriched=#{enr}")

  cond do
    n == 0 -> IO.puts(":: DONE")
    el > deadline -> IO.puts("!! deadline, #{n} jobs left")
    true -> loop.(loop)
  end
end

loop.(loop)

places = Repo.all(GmapsEx.Place)
GmapsEx.Output.Csv.write(places, "/home/nagieeb/Plstka/riyadh-events/riyadh-raw.csv")
IO.puts(":: wrote #{length(places)} places → riyadh-raw.csv")
