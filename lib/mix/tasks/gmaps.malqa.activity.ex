defmodule Mix.Tasks.Gmaps.Malqa.Activity do
  @moduledoc """
  Prove that a candidate is actually trading, not merely listed.

      mix gmaps.malqa.activity --min-reviews 150
      mix gmaps.malqa.activity --limit 800

  The harvest runs search-only, which is fast but returns no evidence of life beyond
  a review count that may be years old. This enriches the flagship branch of each
  candidate brand through the place-detail endpoint, which carries two things a
  search result does not:

    * **`popular_times`** — Google only models an hour-by-hour busyness curve for a
      place it is still seeing live visits to. Its presence is the strongest
      "this place is trading today" signal available without a browser.
    * **`open_hours`** — a maintained listing.

  Review recency would be better still, but the reviews RPC returns 403 from a
  single IP without a browser backend, so it is not available here.
  """

  use Mix.Task

  import Ecto.Query

  alias GmapsEx.{Repo, Whitespace}
  alias GmapsEx.Workers.PlaceWorker

  @shortdoc "Enrich candidate flagships to prove they are trading"

  @switches [
    min_reviews: :integer,
    limit: :integer,
    concurrency: :integer,
    timeout: :integer,
    dry_run: :boolean,
    report: :boolean
  ]

  @tracks [
    {:a, ["malqa:site:%", "malqa:twin:%"], {16.0, 34.0, 33.0, 56.0}},
    {:a2, ["malqa:kitchen:%"], {16.0, 34.0, 33.0, 56.0}},
    {:ksa, ["malqa:ksa:%"], {16.0, 34.0, 33.0, 56.0}},
    {:b, ["malqa:eg:%"], {21.5, 24.5, 32.5, 37.0}}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    Mix.Task.run("app.start")

    if opts[:report] do
      report()
    else
      enrich(opts)
    end
  end

  defp enrich(opts) do
    min_reviews = opts[:min_reviews] || 120
    limit = opts[:limit] || 1200

    flagships =
      @tracks
      |> Enum.flat_map(fn {_t, prefixes, bbox} ->
        Whitespace.brands(prefixes: prefixes, bbox: bbox)
        |> Enum.filter(&((&1[:total_reviews] || 0) >= min_reviews))
        |> Enum.map(& &1[:brand_key])
      end)
      |> Enum.uniq()
      |> flagship_places(limit)

    Mix.shell().info(":: #{length(flagships)} flagship branches to enrich")

    if opts[:dry_run] do
      Mix.shell().info(":: dry-run — nothing enqueued")
      System.halt(0)
    end

    jobs =
      Enum.map(flagships, fn p ->
        PlaceWorker.new(%{
          "data_id" => p.data_id,
          "lang" => "ar",
          "gl" => if(String.starts_with?(p.input_id, "malqa:eg"), do: "eg", else: "sa"),
          "input_id" => p.input_id
        })
      end)

    Oban.scale_queue(queue: :place, limit: opts[:concurrency] || 10)

    inserted =
      jobs
      |> Enum.chunk_every(1000)
      |> Enum.reduce(0, fn chunk, acc ->
        {n, _} = Oban.insert_all(chunk) |> then(&{length(&1), &1})
        acc + n
      end)

    Mix.shell().info(":: enqueued #{inserted} detail fetches — poll with --report")
  end

  # One branch per brand: the busiest, since it is the one most likely to carry a
  # popularity model.
  defp flagship_places(brand_keys, limit) do
    Repo.all(
      from(p in "places",
        where: p.brand_key in ^brand_keys and not is_nil(p.data_id),
        select: %{
          data_id: p.data_id,
          brand_key: p.brand_key,
          input_id: p.input_id,
          rc: p.review_count
        }
      ),
      timeout: :infinity
    )
    |> Enum.group_by(& &1.brand_key)
    |> Enum.map(fn {_k, ps} -> Enum.max_by(ps, &(&1.rc || 0)) end)
    |> Enum.sort_by(&(-(&1.rc || 0)))
    |> Enum.take(limit)
  end

  defp report do
    %{rows: [[total, pt, hours, closed]]} =
      Repo.query!("""
      SELECT count(*),
             count(*) FILTER (WHERE popular_times <> '{}'),
             count(*) FILTER (WHERE open_hours <> '{}'),
             count(*) FILTER (WHERE coalesce(status,'') <> '')
        FROM places WHERE input_id LIKE 'malqa:%'
      """)

    Mix.shell().info("""
    :: enriched coverage
       places            #{total}
       popular_times     #{pt}
       open_hours        #{hours}
       status set        #{closed}
    """)

    pending =
      Repo.one(
        from(j in "oban_jobs",
          where: j.queue == "place" and j.state in ["available", "executing", "retryable"],
          select: count(j.id)
        )
      )

    Mix.shell().info(":: place jobs pending: #{pending}")
  end

  @doc """
  Activity score 0–1 for one place row.

  `popular_times` dominates: Google builds that curve from live visit data, so its
  presence is near-proof the place is trading now. Everything else is weaker
  circumstantial evidence.
  """
  @spec score(map()) :: float()
  def score(row) do
    pt = map_size(row[:popular_times] || %{}) > 0
    hours = map_size(row[:open_hours] || %{}) > 0
    closed = to_string(row[:status] || "") != ""

    cond do
      closed -> 0.0
      pt and hours -> 1.0
      pt -> 0.9
      hours -> 0.55
      true -> 0.3
    end
  end
end
