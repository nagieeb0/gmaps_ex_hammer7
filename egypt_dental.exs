# Saudi Arabia medical sweep for Dactarly lead generation.
# Provider kinds mirror Dactarly.Directory.Provider :kind — doctor, hospital,
# clinic, lab, radiology — so every scraped row maps to a real tenant type.
#
# Seeds are city-major: everything for Riyadh, then Jeddah, and so on, so a run
# stopped early still leaves the biggest markets complete.
import Ecto.Query
alias GmapsEx.Repo

# {tag, lat, lon, half_width_km, half_height_km, cell_km, :full | :core}
cities = [
  {"cairo",        30.05, 31.25, 18.0, 18.0, 4.0, :full},
  {"giza",         30.01, 31.21, 10.0, 10.0, 4.0, :full},
  {"new-cairo",    30.03, 31.47, 10.0, 10.0, 4.0, :full},
  {"6-october",    29.95, 30.92, 10.0, 10.0, 4.0, :full},
  {"shubra",       30.13, 31.24,  6.0,  6.0, 4.0, :core},
  {"alexandria",   31.20, 29.92, 14.0,  8.0, 4.0, :full},
  {"tanta",        30.79, 31.00,  5.0,  5.0, 4.0, :core},
  {"mansoura",     31.04, 31.38,  5.0,  5.0, 4.0, :core},
  {"zagazig",      30.59, 31.50,  5.0,  5.0, 4.0, :core},
  {"mahalla",      30.97, 31.17,  5.0,  5.0, 4.0, :core},
  {"damanhour",    31.03, 30.47,  5.0,  5.0, 4.0, :core},
  {"kafr-el-sheikh",31.11,30.94,  4.0,  4.0, 4.0, :core},
  {"damietta",     31.42, 31.81,  4.0,  4.0, 4.0, :core},
  {"banha",        30.46, 31.18,  4.0,  4.0, 4.0, :core},
  {"shibin",       30.55, 31.01,  4.0,  4.0, 4.0, :core},
  {"port-said",    31.27, 32.30,  5.0,  5.0, 4.0, :core},
  {"ismailia",     30.59, 32.27,  5.0,  5.0, 4.0, :core},
  {"suez",         29.97, 32.55,  5.0,  5.0, 4.0, :core},
  {"fayoum",       29.31, 30.84,  5.0,  5.0, 4.0, :core},
  {"beni-suef",    29.07, 31.08,  4.0,  4.0, 4.0, :core},
  {"minya",        28.11, 30.75,  4.0,  4.0, 4.0, :core},
  {"asyut",        27.18, 31.18,  5.0,  5.0, 4.0, :core},
  {"sohag",        26.56, 31.69,  4.0,  4.0, 4.0, :core},
  {"qena",         26.16, 32.72,  4.0,  4.0, 4.0, :core},
  {"luxor",        25.69, 32.64,  5.0,  5.0, 4.0, :core},
  {"aswan",        24.09, 32.90,  5.0,  5.0, 4.0, :core},
  {"hurghada",     27.26, 33.81,  6.0,  5.0, 4.0, :core},
  {"sharm",        27.92, 34.33,  5.0,  5.0, 4.0, :core}
]

# input_id carries "<kind>:<city>" so a scraped row lands on a Dactarly kind
# without a second classification pass.
core = [
  {"معمل أسنان", "lab"},
  {"مختبر أسنان", "lab"},
  {"مستلزمات طب الأسنان", "supplier"},
  {"أجهزة طب الأسنان", "supplier"},
  {"شركة مستلزمات طبية", "supplier"},
  {"معرض أجهزة طبية", "supplier"},
  {"أشعة أسنان بانوراما", "radiology"},
  {"أكاديمية طب الأسنان", "education"}
]

full = core

frange = fn a, b, s -> Stream.unfold(a, &if(&1 >= b, do: nil, else: {&1, &1 + s})) |> Enum.to_list() end

grid = fn lat, lon, hw, hh, cell ->
  step_lat = cell / 110.574
  step_lon = cell / (111.320 * :math.cos(lat * :math.pi() / 180.0))
  min_lat = lat - hh / 110.574
  max_lat = lat + hh / 110.574
  min_lon = lon - hw / (111.320 * :math.cos(lat * :math.pi() / 180.0))
  max_lon = lon + hw / (111.320 * :math.cos(lat * :math.pi() / 180.0))

  for la <- frange.(min_lat, max_lat, step_lat),
      lo <- frange.(min_lon, max_lon, step_lon),
      do: {la + step_lat / 2, lo + step_lon / 2}
end

seeds =
  Enum.flat_map(cities, fn {tag, lat, lon, hw, hh, cell, depth} ->
    cells = grid.(lat, lon, hw, hh, cell)
    queries = if depth == :full, do: full, else: core

    for {q, kind} <- queries, {la, lo} <- cells do
      %{query: q, input_id: "dental-#{kind}:#{tag}", lat: la, lon: lo, zoom: 13, lang: "ar", gl: "eg"}
    end
  end)

IO.puts(":: #{length(cities)} cities -> #{length(seeds)} seeds")
{:ok, n} = GmapsEx.Runner.start(seeds)
IO.puts(":: enqueued #{n}")

deadline = String.to_integer(System.get_env("DEADLINE") || "36000")
t0 = System.monotonic_time(:second)
pending = ["available", "executing", "scheduled", "retryable"]

loop = fn loop ->
  Process.sleep(60_000)
  p = Repo.one(from j in "oban_jobs", where: j.state in ^pending, select: count())
  d = Repo.one(from j in "oban_jobs", where: j.state == "discarded", select: count())
  pl = Repo.one(from p in "places", select: count())
  rv = Repo.one(from r in "reviews", select: count())
  el = System.monotonic_time(:second) - t0
  IO.puts("[#{div(el, 60)}m] pending=#{p} discarded=#{d} places=#{pl} reviews=#{rv}")

  cond do
    p == 0 -> IO.puts(":: DONE")
    el > deadline -> IO.puts("!! deadline, #{p} left")
    true -> loop.(loop)
  end
end

loop.(loop)

places = Repo.all(GmapsEx.Place)
GmapsEx.Output.Csv.write(places, "/home/nagieeb/Plstka/ksa-dental/egypt-supply-raw.csv")
IO.puts(":: wrote #{length(places)} places")
