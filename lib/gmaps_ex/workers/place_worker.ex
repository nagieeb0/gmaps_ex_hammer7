defmodule GmapsEx.Workers.PlaceWorker do
  @moduledoc """
  Oban worker. One job per place URL — fetches the HTML, extracts
  `APP_INITIALIZATION_STATE`, parses to a `%GmapsEx.Place{}`, upserts to Postgres.

  Mirrors `PlaceJob` in `gmaps/place.go` but without a browser. If HTML extraction
  fails (the ~5% case), the job ends in `Oban.discarded` for manual inspection —
  no browser fallback (per plan).
  """

  use Oban.Worker,
    queue: :place,
    max_attempts: 3,
    unique: [period: 60 * 60 * 24, fields: [:args]]

  alias GmapsEx.{Exiter, Place, Places, ReviewsPersistence}
  alias GmapsEx.Workers.EmailWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    data_id = args["data_id"] || args["url"]
    lang = args["lang"] || "en"
    gl = args["gl"] || "us"
    tenant_id = args["tenant_id"]
    input_id = args["input_id"]

    case GmapsEx.place(data_id, lang: lang, gl: gl) do
      {:ok, %Place{} = place} ->
        attrs =
          place
          |> Place.to_attrs()
          |> Map.put(:tenant_id, tenant_id)
          |> Map.put(:input_id, input_id || place.input_id)

        case Places.upsert(attrs) do
          {:ok, saved} ->
            inline = get_in(place.extra, ["inline_reviews"]) || []
            review_count = ReviewsPersistence.bulk_upsert(saved.id, inline)
            Exiter.incr_places_completed()

            broadcast(
              {:place_enriched, saved.title, saved.review_count, saved.review_rating,
               review_count}
            )

            # Optional email extraction (off by default; opt in per job).
            if Map.get(args, "extract_emails", false) and is_binary(saved.website) and
                 saved.website != "" do
              Oban.insert(EmailWorker.new(%{"place_id" => saved.id}))
            end

            :telemetry.execute(
              [:gmaps_ex, :place, :ok],
              %{inline_reviews: review_count},
              %{cid: place.cid, title: place.title}
            )

            :ok

          {:error, changeset} ->
            :telemetry.execute([:gmaps_ex, :place, :error], %{}, %{
              data_id: data_id,
              reason: "upsert_failed",
              errors: inspect(changeset.errors)
            })

            {:error, changeset}
        end

      # Non-recoverable: the place's preview URL isn't in the HTML response
      # (Google may have served a captcha or region-restricted variant).
      # Cancel the job rather than burning retries — re-runs of the search
      # will requeue it if the place is still relevant.
      {:error, reason} when reason in [:preview_url_not_found, :app_state_not_found] ->
        :telemetry.execute([:gmaps_ex, :place, :error], %{}, %{
          data_id: data_id,
          reason: Atom.to_string(reason)
        })

        {:cancel, reason}

      {:error, reason} ->
        :telemetry.execute([:gmaps_ex, :place, :error], %{}, %{
          data_id: data_id,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  def perform(job) do
    require Logger

    Logger.warning(
      "PlaceWorker: unexpected job shape #{inspect(job, limit: 5, printable_limit: 200)}"
    )

    {:cancel, :bad_args}
  end

  defp broadcast(msg) do
    if Code.ensure_loaded?(Phoenix.PubSub) and Process.whereis(GmapsEx.PubSub) do
      Phoenix.PubSub.broadcast(GmapsEx.PubSub, "gmaps:events", msg)
    end

    :ok
  end
end
