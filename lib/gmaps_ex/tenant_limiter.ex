defmodule GmapsEx.TenantLimiter do
  @moduledoc """
  Per-tenant scrape rate limiter. Prevents one customer from saturating the
  Oban queue or hitting Google's rate limit on behalf of others.

  Wraps `GmapsEx.Runner.start/1` with a Hammer bucket keyed on `tenant_id`.
  If the tenant has burned through their quota, the call returns
  `{:error, {:rate_limited, retry_after_ms}}` — you typically surface this to
  the user as "your scrape quota is full, try again in 5 minutes".

  ## Configure quotas

  Default: 100 search jobs per tenant per hour.

      config :gmaps_ex, GmapsEx.TenantLimiter,
        max_seeds_per_hour: 100,
        bucket_ms: 60 * 60 * 1000

  Override at the call-site for premium tiers:

      GmapsEx.TenantLimiter.start(seeds, tenant_id: "t-pro-42",
        max_seeds_per_hour: 1000)
  """

  @doc """
  Same shape as `GmapsEx.Runner.start/1`, but checks tenant quota first.

  Returns `{:ok, n}` if all seeds enqueued, `{:error, {:rate_limited, ms}}`
  if the tenant has exceeded their bucket. Partial enqueueing is rejected —
  either all seeds go in or none do.
  """
  @spec start([map()], keyword()) ::
          {:ok, non_neg_integer()} | {:error, {:rate_limited, non_neg_integer()}}
  def start(seeds, opts \\ []) when is_list(seeds) and seeds != [] do
    tenant_id = Keyword.get(opts, :tenant_id) || infer_tenant_id(seeds)

    if tenant_id do
      cfg = Application.get_env(:gmaps_ex, __MODULE__, [])
      max_seeds = opts[:max_seeds_per_hour] || cfg[:max_seeds_per_hour] || 100
      bucket_ms = cfg[:bucket_ms] || 60 * 60 * 1000

      case GmapsEx.RateLimiter.hit("tenant:#{tenant_id}", bucket_ms, max_seeds, length(seeds)) do
        {:allow, _count} ->
          GmapsEx.Runner.start(seeds)

        {:deny, retry_after_ms} ->
          {:error, {:rate_limited, retry_after_ms}}
      end
    else
      # No tenant — bypass the limiter (CLI use, etc.)
      GmapsEx.Runner.start(seeds)
    end
  end

  defp infer_tenant_id(seeds) do
    seeds
    |> Enum.map(&Map.get(&1, :tenant_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [single] -> single
      _ -> nil
    end
  end

  @doc """
  Returns `{used, remaining}` for the given tenant's current bucket.
  Useful for showing quota in your dashboard.
  """
  @spec usage(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def usage(tenant_id) when is_binary(tenant_id) do
    cfg = Application.get_env(:gmaps_ex, __MODULE__, [])
    max_seeds = cfg[:max_seeds_per_hour] || 100
    bucket_ms = cfg[:bucket_ms] || 60 * 60 * 1000

    count = GmapsEx.RateLimiter.get("tenant:#{tenant_id}", bucket_ms)
    {count, max(max_seeds - count, 0)}
  end
end
