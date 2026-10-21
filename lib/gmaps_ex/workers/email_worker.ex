defmodule GmapsEx.Workers.EmailWorker do
  @moduledoc """
  Fetches a place's website + a few common contact pages, regexes email
  addresses, persists them to `places.emails`.

  Mirrors `gmaps/emailjob.go` from the Go scraper. Pure HTTP — no browser.

  ## Heuristics

    * Visits `/`, `/contact`, `/contact-us`, `/about`, `/about-us` if they exist.
    * Skips social-only sites (`facebook.com`, `instagram.com`, `twitter.com`)
      because they don't host the business's own email — matches the
      `IsWebsiteValidForEmail` check in `gmaps/entry.go:127`.
    * Filters out obviously useless emails (`example@example.com`, image-CDN
      noise, prefixed/suffixed nonsense).
  """

  use Oban.Worker,
    queue: :emails,
    max_attempts: 2,
    unique: [period: 60 * 60 * 24 * 7, fields: [:args]]

  import Ecto.Query

  alias GmapsEx.{Http.Client, Place, Repo}

  # Reasonable email regex — RFC 5322 is overkill, and the strictest patterns
  # miss real-world addresses. This catches >99% with very low false-positive
  # rate against typical website copy.
  @email_regex ~r/\b([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})\b/

  @subpaths ~w[/ /contact /contact-us /about /about-us]

  # Ceiling on one subpath fetch. Above Client's own 30s request timeout so a
  # single slow-but-alive host still completes, below its 3-retry worst case so
  # a dead host cannot hold a queue slot for minutes.
  @fetch_timeout_ms 40_000

  @social_blocklist ~w[facebook.com instagram.com twitter.com x.com linkedin.com]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"place_id" => place_id}}) when is_binary(place_id) do
    case Repo.get(Place, place_id) do
      nil ->
        {:cancel, :place_not_found}

      %Place{website: nil} ->
        {:cancel, :no_website}

      %Place{website: ""} ->
        {:cancel, :no_website}

      %Place{website: website} = place ->
        if social_only?(website) do
          {:cancel, :social_only}
        else
          emails = extract_from_website(website)
          persist(place, emails)

          :telemetry.execute([:gmaps_ex, :emails, :ok], %{count: length(emails)}, %{
            place_id: place_id,
            website: website
          })

          :ok
        end
    end
  end

  def perform(_), do: {:cancel, :bad_args}

  defp social_only?(url) when is_binary(url) do
    Enum.any?(@social_blocklist, fn host -> String.contains?(url, host) end)
  end

  defp extract_from_website(url) do
    base =
      url
      |> String.replace_trailing("/", "")
      |> URI.parse()

    @subpaths
    |> Enum.map(fn path ->
      %URI{base | path: path, query: nil, fragment: nil} |> URI.to_string()
    end)
    |> Enum.uniq()
    # Fetched concurrently: sequentially, a job costs the SUM of five fetches,
    # and against dead or slow hosts (Client retries 3× on a 30s timeout) that
    # ran to minutes each and starved the queue. Now a job costs the slowest
    # single fetch, hard-capped by @fetch_timeout_ms.
    |> Task.async_stream(&fetch_emails/1,
      max_concurrency: length(@subpaths),
      timeout: @fetch_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, emails} -> emails
      {:exit, _reason} -> []
    end)
    |> Enum.uniq()
    |> Enum.reject(&junk?/1)
    |> Enum.take(10)
  end

  defp fetch_emails(url) do
    case Client.get(url) do
      {:ok, body, _hdrs} ->
        @email_regex
        |> Regex.scan(body, capture: :all_but_first)
        |> Enum.map(fn [e] -> e end)
        |> Enum.map(&String.downcase/1)

      _ ->
        []
    end
  end

  # Filter out typical false positives. Tighten over time as real noise appears.
  defp junk?(email) do
    String.contains?(email, "@example.") or
      String.contains?(email, "@sentry.") or
      String.contains?(email, "@your") or
      String.contains?(email, "wixpress.com") or
      String.contains?(email, "@2x") or
      String.contains?(email, ".png") or
      String.contains?(email, ".jpg") or
      String.contains?(email, ".gif")
  end

  defp persist(%Place{} = place, emails) do
    existing = place.emails || []
    merged = (existing ++ emails) |> Enum.uniq() |> Enum.take(20)

    place
    |> Ecto.Changeset.change(emails: merged)
    |> Repo.update()
  end

  @doc """
  Enqueue email extraction for every place that has a website and no emails yet.
  Convenient one-shot from IEx or a cron job.
  """
  @spec enqueue_for_pending() :: non_neg_integer()
  def enqueue_for_pending do
    Place
    |> where([p], not is_nil(p.website) and p.website != "")
    |> where([p], fragment("coalesce(array_length(?, 1), 0) = 0", p.emails))
    |> select([p], p.id)
    |> Repo.all()
    |> Enum.map(fn id -> new(%{"place_id" => id}) end)
    # Chunk to stay under PostgreSQL's 65,535-parameter cap — a single
    # insert_all of tens of thousands of jobs blows the protocol limit
    # (same guard as GmapsEx.Runner.start/1).
    |> Enum.chunk_every(1_000)
    |> Enum.flat_map(&Oban.insert_all/1)
    |> length()
  end
end
