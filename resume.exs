# Re-run the search jobs the cardinality bug discarded (and the 4 that hung),
# then drain. Same node, so Dedupe is warm for the retried batch.
import Ecto.Query
alias GmapsEx.Repo

{n, _} =
  Repo.update_all(
    from(j in "oban_jobs", where: j.state in ["discarded", "executing"] and j.queue == "search"),
    set: [state: "available", attempt: 0, errors: [], attempted_at: nil,
          discarded_at: nil, completed_at: nil, scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)]
  )

IO.puts(":: requeued #{n} search jobs")

t0 = System.monotonic_time(:second)
pending = ["available", "executing", "scheduled", "retryable"]

loop = fn loop ->
  Process.sleep(20_000)
  p = Repo.one(from j in "oban_jobs", where: j.state in ^pending, select: count())
  d = Repo.one(from j in "oban_jobs", where: j.state == "discarded", select: count())
  pl = Repo.one(from p in "places", select: count())
  el = System.monotonic_time(:second) - t0
  IO.puts("[#{div(el, 60)}m] pending=#{p} discarded=#{d} places=#{pl}")
  cond do
    p == 0 -> IO.puts(":: DONE")
    el > 1800 -> IO.puts("!! deadline, #{p} left")
    true -> loop.(loop)
  end
end

loop.(loop)

places = Repo.all(GmapsEx.Place)
GmapsEx.Output.Csv.write(places, "/home/nagieeb/Plstka/riyadh-events/riyadh-raw.csv")
IO.puts(":: wrote #{length(places)} places → riyadh-raw.csv")
