defmodule GmapsEx.Workers.SearchWorker do
  @moduledoc """
  Oban worker. One job per (keyword, viewport) — calls the XHR search endpoint,
  parses results, enqueues a `PlaceWorker` job for each result we haven't seen.

  Mirrors `SearchJob` in `gmaps/searchjob.go` but with persistent retries and
  exponential backoff handled by Oban.
  """

  use Oban.Worker,
    queue: :search,
    max_attempts: 3,
    unique: [period: 60 * 60, fields: [:args]]

  alias GmapsEx.{Dedupe, Exiter, Place, Places}
  alias GmapsEx.Workers.PlaceWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    lang = args["lang"] || "en"
    gl = args["gl"] || "us"
    tenant_id = args["tenant_id"]
    input_id = args["input_id"]
    extract_emails = Map.get(args, "extract_emails", false)

    opts = [
      lat: args["lat"],
      lon: args["lon"],
      zoom: args["zoom"],
      lang: lang
    ]

    case GmapsEx.search(args["query"], opts) do
      {:ok, places} ->
        new_places =
          Enum.filter(places, fn p ->
            key = dedupe_key(p)
            key && Dedupe.add_if_not_exists(key)
          end)

        # Upsert search-level attrs directly — covers the 13 fields the search
        # XHR exposes. PlaceWorker then enriches with the remaining ~20 fields
        # (full hours, reviews count, about, reservations, full website, etc.).
        Enum.each(new_places, fn p ->
          p
          |> Place.to_attrs()
          |> Map.put(:tenant_id, tenant_id)
          |> Map.put(:input_id, input_id || p.input_id)
          |> Places.upsert()
        end)

        broadcast({:places_found, args["query"], length(new_places)})

        enrich? = Map.get(args, "enrich", true)

        enrich_jobs =
          if enrich? do
            # uniq_by/2 is load-bearing: Oban's `unique:` compiles to ON CONFLICT,
            # and two identical args inside ONE insert_all raise
            # cardinality_violation, discarding the whole search job.
            new_places
            |> Enum.uniq_by(& &1.data_id)
            |> Enum.flat_map(fn p ->
              case p.data_id do
                id when is_binary(id) and id != "" ->
                  [
                    PlaceWorker.new(%{
                      "data_id" => id,
                      "lang" => lang,
                      "gl" => gl,
                      "tenant_id" => tenant_id,
                      "input_id" => input_id,
                      # PlaceWorker is what actually queues EmailWorker, so the
                      # seed's opt-in has to ride along here — otherwise
                      # `extract_emails: true` on a run is silently a no-op.
                      "extract_emails" => extract_emails
                    })
                  ]

                _ ->
                  []
              end
            end)
          else
            []
          end

        if enrich_jobs != [], do: Oban.insert_all(enrich_jobs)

        Exiter.incr_seed_completed()
        Exiter.incr_places_found(length(enrich_jobs))

        :telemetry.execute(
          [:gmaps_ex, :search, :ok],
          %{count: length(new_places), enriching: length(enrich_jobs)},
          %{query: args["query"]}
        )

        :ok

      {:error, reason} ->
        broadcast({:search_error, args["query"], reason})

        :telemetry.execute([:gmaps_ex, :search, :error], %{}, %{
          query: args["query"],
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  defp dedupe_key(%{data_id: id}) when is_binary(id) and id != "", do: id
  defp dedupe_key(%{place_id: id}) when is_binary(id) and id != "", do: id
  defp dedupe_key(_), do: nil

  defp broadcast(msg) do
    if Code.ensure_loaded?(Phoenix.PubSub) and Process.whereis(GmapsEx.PubSub) do
      Phoenix.PubSub.broadcast(GmapsEx.PubSub, "gmaps:events", msg)
    end

    :ok
  end
end
