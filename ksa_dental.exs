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
  {"riyadh",        24.71, 46.68, 24.0, 22.0, 3.5, :full},
  {"jeddah",        21.54, 39.19, 16.0, 12.0, 3.5, :full},
  {"mecca",         21.39, 39.86, 10.0, 10.0, 3.5, :full},
  {"medina",        24.47, 39.61, 10.0, 10.0, 3.5, :full},
  {"dammam",        26.43, 50.10, 10.0,  8.0, 3.5, :full},
  {"khobar",        26.28, 50.21,  8.0,  6.0, 3.5, :full},
  {"dhahran",       26.29, 50.13,  5.0,  5.0, 4.0, :core},
  {"qatif",         26.56, 50.01,  8.0,  8.0, 4.0, :core},
  {"jubail",        27.01, 49.66,  8.0,  8.0, 4.0, :core},
  {"al-ahsa",       25.38, 49.59, 12.0, 12.0, 4.0, :full},
  {"taif",          21.27, 40.42,  8.0,  8.0, 4.0, :full},
  {"buraidah",      26.33, 43.97,  8.0,  8.0, 4.0, :full},
  {"unaizah",       26.09, 43.99,  5.0,  5.0, 4.0, :core},
  {"tabuk",         28.38, 36.57,  8.0,  8.0, 4.0, :full},
  {"hail",          27.52, 41.69,  7.0,  7.0, 4.0, :core},
  {"abha",          18.22, 42.51,  6.0,  6.0, 4.0, :full},
  {"khamis-mushait",18.31, 42.73,  8.0,  8.0, 4.0, :core},
  {"najran",        17.49, 44.13,  8.0,  8.0, 4.0, :core},
  {"jazan",         16.89, 42.57,  6.0,  6.0, 4.0, :core},
  {"yanbu",         24.09, 38.06,  8.0,  8.0, 4.0, :core},
  {"al-kharj",      24.15, 47.33,  7.0,  7.0, 4.0, :core},
  {"hafar-al-batin",28.43, 45.97,  7.0,  7.0, 4.0, :core},
  {"arar",          30.98, 41.04,  5.0,  5.0, 4.0, :core},
  {"sakaka",        29.97, 40.21,  5.0,  5.0, 4.0, :core},
  {"al-baha",       20.01, 41.47,  4.0,  4.0, 4.0, :core},
  {"qurayyat",      31.33, 37.34,  4.0,  4.0, 4.0, :core},
  {"bisha",         20.00, 42.60,  4.0,  4.0, 4.0, :core},
  {"dawadmi",       24.51, 44.39,  4.0,  4.0, 4.0, :core},
  {"zulfi",         26.30, 44.81,  4.0,  4.0, 4.0, :core},
  {"majmaah",       25.90, 45.34,  4.0,  4.0, 4.0, :core},
  {"wadi-dawasir",  20.47, 44.79,  4.0,  4.0, 4.0, :core},
  {"rabigh",        22.80, 39.03,  4.0,  4.0, 4.0, :core},
  {"al-rass",       25.87, 43.50,  4.0,  4.0, 4.0, :core},
  {"sharurah",      17.47, 47.11,  3.0,  3.0, 4.0, :core},
  {"turaif",        31.68, 38.66,  3.0,  3.0, 4.0, :core}
]

# input_id carries "<kind>:<city>" so a scraped row lands on a Dactarly kind
# without a second classification pass.
core = [
  {"مختبر أسنان", "lab"},
  {"مستلزمات طب الأسنان", "supplier"},
  {"أجهزة طب الأسنان", "supplier"},
  {"شركة مستلزمات طبية", "supplier"},
  {"معرض أجهزة طبية", "supplier"},
  {"تقويم أسنان", "doctor"},
  {"زراعة أسنان", "clinic"},
  {"عيادة أسنان أطفال", "clinic"},
  {"جراحة الفم والأسنان", "doctor"},
  {"مركز أسنان تخصصي", "clinic"},
  {"ابتسامة هوليود", "clinic"},
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
      %{query: q, input_id: "dental-#{kind}:#{tag}", lat: la, lon: lo, zoom: 13, lang: "ar", gl: "sa"}
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
GmapsEx.Output.Csv.write(places, "/home/nagieeb/Plstka/ksa-dental/ksa-dental-raw.csv")
IO.puts(":: wrote #{length(places)} places")
