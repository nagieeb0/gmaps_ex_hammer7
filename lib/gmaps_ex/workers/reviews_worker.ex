defmodule GmapsEx.Workers.ReviewsWorker do
  @moduledoc """
  Oban worker. Fetches *all* reviews for one place via paginated RPC calls,
  persists them, and broadcasts a `:reviews_fetched` PubSub event.

  Enqueued by `PlaceWorker` for any place with `review_count > 0`.
  """

  use Oban.Worker,
    queue: :reviews,
    max_attempts: 3,
    unique: [period: 60 * 60 * 24, fields: [:args]]

  alias GmapsEx.{Place, Repo, ReviewsPersistence}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    data_id = args["data_id"]
    lang = args["lang"] || "en"
    gl = args["gl"] || "us"
    max_pages = args["max_pages"] || 100

    backend =
      Application.get_env(:gmaps_ex, __MODULE__, [])
      |> Keyword.get(:backend, GmapsEx.Reviews.Backend.Http)

    with %Place{id: place_id} = place <- Repo.get_by(Place, data_id: data_id),
         {:ok, reviews} <-
           backend.fetch_all(data_id, lang: lang, gl: gl, max_pages: max_pages) do
      count = ReviewsPersistence.bulk_upsert(place_id, reviews)
      broadcast({:reviews_fetched, place.title, count})

      :telemetry.execute([:gmaps_ex, :reviews, :ok], %{count: count}, %{
        data_id: data_id,
        title: place.title
      })

      :ok
    else
      nil ->
        :telemetry.execute([:gmaps_ex, :reviews, :error], %{}, %{
          data_id: data_id,
          reason: "place_not_found"
        })

        {:cancel, :place_not_found}

      {:error, reason} ->
        :telemetry.execute([:gmaps_ex, :reviews, :error], %{}, %{
          data_id: data_id,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  def perform(job) do
    require Logger
    Logger.warning("ReviewsWorker: unexpected job shape #{inspect(job, limit: 3)}")
    {:cancel, :bad_args}
  end

  defp broadcast(msg) do
    if Code.ensure_loaded?(Phoenix.PubSub) and Process.whereis(GmapsEx.PubSub) do
      Phoenix.PubSub.broadcast(GmapsEx.PubSub, "gmaps:events", msg)
    end

    :ok
  end
end
