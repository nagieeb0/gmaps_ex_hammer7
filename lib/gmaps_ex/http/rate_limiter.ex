defmodule GmapsEx.Http.RateLimiter do
  @moduledoc """
  Per-proxy rate limiter on top of `Hammer`. Defaults to 1 request/second/proxy
  (Webshare residential proxies handle this well; bursting will trigger 429s).

  Use:

      case RateLimiter.check(proxy_id) do
        :ok -> Client.get(...)
        {:wait, ms} -> Process.sleep(ms); ...
      end
  """

  @doc "Returns `:ok` if the request is allowed; `{:wait, ms}` if rate-limited."
  @spec check(String.t() | nil) :: :ok | {:wait, non_neg_integer()}
  def check(nil), do: :ok

  def check(proxy_id) when is_binary(proxy_id) do
    rps = Application.get_env(:gmaps_ex, __MODULE__, [])[:per_proxy_per_second] || 1
    scale_ms = 1_000

    case GmapsEx.RateLimiter.hit("proxy:#{proxy_id}", scale_ms, rps) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:wait, retry_after_ms}
    end
  end
end
