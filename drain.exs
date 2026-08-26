# ponytail: gmaps.scrape's --wait returns before place-enrichment jobs run.
# Poll Oban until the queues are empty (or the deadline passes), then stop.
import Ecto.Query
alias GmapsEx.Repo

deadline_s = String.to_integer(System.get_env("DRAIN_TIMEOUT") || "3600")
t0 = System.monotonic_time(:second)
pending = ["available", "executing", "scheduled", "retryable"]

loop = fn loop ->
  n = Repo.one(from j in "oban_jobs", where: j.state in ^pending, select: count())
  places = Repo.one(from p in "places", select: count())
  enriched = Repo.one(from p in "places", where: not is_nil(p.category), select: count())
  IO.puts("#{Time.utc_now() |> Time.truncate(:second)}  pending=#{n}  places=#{places}  enriched=#{enriched}")

  cond do
    n == 0 -> :done
    System.monotonic_time(:second) - t0 > deadline_s -> IO.puts("!! deadline hit, #{n} jobs left"); :timeout
    true -> Process.sleep(15_000); loop.(loop)
  end
end

loop.(loop)
