defmodule GmapsEx.Http.Client do
  @moduledoc """
  Req wrapper that handles Google Maps' consent cookie, user-agent rotation,
  retries, and proxy checkout from `GmapsEx.Http.ProxyPool`.

  Anti-detection rules (from reading the Go scraper):

    * Pre-set `CONSENT=YES+` cookie on every request to skip the EU consent interstitial
      (matches the JS click in `gmaps/job.go:275-298`).
    * Rotate User-Agent per request from a configured Firefox+Chrome list.
    * Retry up to `max_retries` on 429 + 5xx with exponential backoff.
    * On 429 from a specific proxy, mark it dead before retrying.
  """

  alias GmapsEx.Http.{ProxyPool, SessionStore}

  require Logger

  @doc """
  Issue a GET request. Returns `{:ok, body, headers}` on success.
  """
  @spec get(String.t(), keyword()) :: {:ok, binary(), map()} | {:error, term()}
  def get(url, opts \\ []) do
    cfg = Application.fetch_env!(:gmaps_ex, __MODULE__)
    pool_id = Keyword.get(opts, :pool_id, "default")

    headers = [
      {"user-agent", pick_user_agent(cfg)},
      {"accept",
       "text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7"},
      {"accept-language", Keyword.get(opts, :accept_language, "en-US,en;q=0.9")},
      {"sec-fetch-dest", "document"},
      {"sec-fetch-mode", "navigate"},
      {"sec-fetch-site", "none"},
      {"cookie", SessionStore.cookie_header(pool_id)}
    ]

    params = Keyword.get(opts, :params, [])
    proxy = Keyword.get(opts, :proxy, ProxyPool.checkout())

    req_opts =
      [
        url: url,
        method: :get,
        headers: headers,
        params: params,
        receive_timeout: cfg[:request_timeout_ms],
        retry: false,
        decode_body: false
      ]
      |> maybe_with_proxy(proxy)

    case execute_with_retry(req_opts, proxy, cfg[:max_retries]) do
      {:ok, %Req.Response{status: status, body: body, headers: hdrs}} when status in 200..299 ->
        # Capture any new cookies Google sets — long-running scrapes need this
        # to keep `NID` and friends from drifting out of date.
        store_response_cookies(pool_id, hdrs)
        {:ok, body, hdrs}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_response_cookies(pool_id, hdrs) when is_map(hdrs) do
    case Map.get(hdrs, "set-cookie") do
      nil -> :ok
      values when is_list(values) -> SessionStore.merge_set_cookies(pool_id, values)
      value when is_binary(value) -> SessionStore.merge_set_cookies(pool_id, [value])
    end
  end

  defp store_response_cookies(pool_id, hdrs) when is_list(hdrs) do
    values =
      hdrs
      |> Enum.filter(fn {k, _} -> String.downcase(k) == "set-cookie" end)
      |> Enum.flat_map(fn {_, v} -> List.wrap(v) end)

    SessionStore.merge_set_cookies(pool_id, values)
  end

  defp store_response_cookies(_, _), do: :ok

  defp execute_with_retry(req_opts, _proxy, 0), do: Req.request(req_opts)

  defp execute_with_retry(req_opts, proxy, retries_left) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status}} = ok when status in 200..299 ->
        ok

      {:ok, %Req.Response{status: 429}} ->
        Logger.warning("429 received, rotating proxy", retries_left: retries_left)
        if proxy, do: ProxyPool.mark_dead(proxy)
        backoff(retries_left)
        execute_with_retry(req_opts, proxy, retries_left - 1)

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        backoff(retries_left)
        execute_with_retry(req_opts, proxy, retries_left - 1)

      {:ok, _} = result ->
        result

      {:error, _reason} = err ->
        if retries_left > 1 do
          backoff(retries_left)
          execute_with_retry(req_opts, proxy, retries_left - 1)
        else
          err
        end
    end
  end

  defp backoff(retries_left) do
    base = 500
    jitter = :rand.uniform(1_000)
    sleep_ms = base * round(:math.pow(2, 3 - retries_left)) + jitter
    Process.sleep(sleep_ms)
  end

  defp pick_user_agent(cfg) do
    cfg[:user_agents] |> Enum.random()
  end

  defp maybe_with_proxy(req_opts, nil), do: req_opts

  defp maybe_with_proxy(req_opts, %{} = proxy) do
    proxy_url =
      case proxy.userinfo do
        nil -> "#{proxy.scheme}://#{proxy.host}:#{proxy.port}"
        info -> "#{proxy.scheme}://#{info}@#{proxy.host}:#{proxy.port}"
      end

    Keyword.put(req_opts, :connect_options,
      proxy: {proxy_scheme_atom(proxy.scheme), proxy.host, proxy.port, []}
    )
    |> Keyword.put(:proxy_headers, proxy_basic_auth(proxy))
    |> Keyword.put(:proxy_url, proxy_url)
  end

  defp proxy_scheme_atom("https"), do: :https
  defp proxy_scheme_atom(_), do: :http

  defp proxy_basic_auth(%{userinfo: nil}), do: []

  defp proxy_basic_auth(%{userinfo: info}) do
    [{"proxy-authorization", "Basic " <> Base.encode64(info)}]
  end
end
