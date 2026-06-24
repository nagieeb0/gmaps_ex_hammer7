defmodule Mix.Tasks.Gmaps.Refresh do
  @moduledoc """
  Re-enrich places older than N days. Useful as a daily cron.

  Walks the `places` table for rows whose `updated_at` is older than the
  threshold, has a `data_id`, and enqueues a fresh `PlaceWorker` job for each
  one. Existing rows update in-place (no duplicates) — review counts, hours,
  status, and inline reviews all refresh.

  ## Examples

      # Refresh every place not touched in 7 days
      mix gmaps.refresh --older-than 7

      # Refresh only a tenant's places
      mix gmaps.refresh --older-than 30 --tenant t-pro-42

      # Limit batch size (don't blast 10K jobs at once)
      mix gmaps.refresh --older-than 14 --limit 1000

      # Filter by region (uses places.input_id)
      mix gmaps.refresh --older-than 30 --input-prefix "egypt-dentists:cairo"

  ## Schedule it

  In your host app's Oban config:

      config :my_app, Oban,
        plugins: [
          {Oban.Plugins.Cron, crontab: [
            {"0 3 * * *", MyApp.NightlyRefresh}
          ]}
        ]

  And:

      defmodule MyApp.NightlyRefresh do
        use Oban.Worker, queue: :default
        @impl true
        def perform(_), do: Mix.Tasks.Gmaps.Refresh.refresh(older_than_days: 7)
      end
  """

  use Mix.Task

  import Ecto.Query

  alias GmapsEx.{Place, Repo}
  alias GmapsEx.Workers.PlaceWorker

  @shortdoc "Re-enrich places that haven't been scraped in N days"

  @switches [
    older_than: :integer,
    tenant: :string,
    limit: :integer,
    input_prefix: :string,
    dry_run: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    Mix.Task.run("app.start")

    {n_found, n_enqueued} =
      refresh(
        older_than_days: opts[:older_than] || 7,
        tenant_id: opts[:tenant],
        limit: opts[:limit],
        input_prefix: opts[:input_prefix],
        dry_run: opts[:dry_run]
      )

    if opts[:dry_run] do
      Mix.shell().info(":: dry-run: would refresh #{n_found} places")
    else
      Mix.shell().info(":: enqueued #{n_enqueued} refresh jobs (of #{n_found} candidates)")
    end
  end

  @doc """
  Programmatic version. Returns `{found, enqueued}`.

  Options:
    * `:older_than_days` (default 7)
    * `:tenant_id` — scope to one tenant
    * `:limit` — cap the number of jobs enqueued in one batch
    * `:input_prefix` — only refresh places whose `input_id` starts with this string
    * `:dry_run` — just count, don't enqueue
  """
  @spec refresh(keyword()) :: {non_neg_integer(), non_neg_integer()}
  def refresh(opts \\ []) do
    days = opts[:older_than_days] || 7
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    base =
      Place
      |> where([p], not is_nil(p.data_id) and p.data_id != "")
      |> where([p], p.updated_at < ^cutoff)

    q =
      base
      |> maybe_filter_tenant(opts[:tenant_id])
      |> maybe_filter_prefix(opts[:input_prefix])
      |> maybe_limit(opts[:limit])
      |> select([p], %{data_id: p.data_id, tenant_id: p.tenant_id, input_id: p.input_id})

    candidates = Repo.all(q)
    n_found = length(candidates)

    if opts[:dry_run] do
      {n_found, 0}
    else
      jobs =
        Enum.map(candidates, fn p ->
          PlaceWorker.new(%{
            "data_id" => p.data_id,
            "tenant_id" => p.tenant_id,
            "input_id" => p.input_id,
            "lang" => "en",
            "gl" => "us"
          })
        end)

      inserted =
        case jobs do
          [] -> []
          _ -> Oban.insert_all(jobs)
        end

      {n_found, length(inserted)}
    end
  end

  defp maybe_filter_tenant(q, nil), do: q
  defp maybe_filter_tenant(q, tid), do: where(q, [p], p.tenant_id == ^tid)

  defp maybe_filter_prefix(q, nil), do: q

  defp maybe_filter_prefix(q, prefix),
    do: where(q, [p], ilike(p.input_id, ^"#{prefix}%"))

  defp maybe_limit(q, nil), do: q
  defp maybe_limit(q, n) when is_integer(n), do: limit(q, ^n)
end
