defmodule GmapsEx.Reviews.Backend.Chain do
  @moduledoc """
  Tries multiple backends in order, falling back when one fails or returns
  too few reviews. Designed for the `HTTP → Lightpanda → Playwright` pattern.

  ## Use it

      config :gmaps_ex, GmapsEx.Workers.ReviewsWorker,
        backend: {GmapsEx.Reviews.Backend.Chain, [
          GmapsEx.Reviews.Backend.Http,
          GmapsEx.Reviews.Backend.Lightpanda,
          GmapsEx.Reviews.Backend.Playwright
        ]}

  A backend "succeeds" when it returns `{:ok, reviews}` with at least
  `:min_reviews` items (configurable, default 5). Anything less is treated
  as a failure and we move to the next backend.

  ## Why this pattern

  * **HTTP** — costs nothing, instant. Works for ~95% of places via inline reviews.
  * **Lightpanda** — V8-based ~10× lighter than Chromium. Tries when HTTP returns < 5 reviews.
  * **Playwright** — heavy Chromium fallback. Final answer for places where Lightpanda fails.

  Total cost per place: avg ~1 HTTP call, occasionally a browser launch.
  """

  @behaviour GmapsEx.Reviews.Backend

  @min_reviews 5

  @impl true
  def fetch_all(data_id, opts) do
    backends = opts[:backends] || default_backends()
    min_reviews = opts[:min_reviews] || @min_reviews
    try_chain(backends, data_id, opts, min_reviews, [])
  end

  defp try_chain([], _data_id, _opts, _min, errors) do
    {:error, {:all_backends_failed, Enum.reverse(errors)}}
  end

  defp try_chain([backend | rest], data_id, opts, min, errors) do
    case backend.fetch_all(data_id, opts) do
      {:ok, reviews} when length(reviews) >= min ->
        {:ok, reviews}

      {:ok, reviews} ->
        # Got some reviews but not enough — try next backend.
        # If next backend also returns too few, we'll return the highest count.
        case try_chain(rest, data_id, opts, min, [{backend, :too_few, length(reviews)} | errors]) do
          {:ok, more} when length(more) > length(reviews) -> {:ok, more}
          _ -> {:ok, reviews}
        end

      {:error, reason} ->
        try_chain(rest, data_id, opts, min, [{backend, :error, reason} | errors])
    end
  end

  defp default_backends do
    Enum.filter(
      [
        GmapsEx.Reviews.Backend.Http,
        if(Code.ensure_loaded?(GmapsEx.Reviews.Backend.Lightpanda),
          do: GmapsEx.Reviews.Backend.Lightpanda
        ),
        if(Code.ensure_loaded?(GmapsEx.Reviews.Backend.Playwright),
          do: GmapsEx.Reviews.Backend.Playwright
        )
      ],
      & &1
    )
  end
end
