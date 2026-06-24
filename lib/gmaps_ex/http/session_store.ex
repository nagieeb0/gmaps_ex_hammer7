defmodule GmapsEx.Http.SessionStore do
  @moduledoc """
  Per-proxy cookie jar.

  Google's review-pagination XHR (`/maps/rpc/listugcposts`) refuses to return
  data unless the request carries the cookies a real browser collects after
  visiting `https://www.google.com/maps`. The Go scraper sidesteps this by
  doing the RPC call from *inside* a Playwright browser context — the browser
  sends the cookies automatically (see `gmaps/reviews.go:104-123`).

  We do the same trick without a browser: hit `maps.google.com` once per proxy
  to harvest `Set-Cookie` headers (`NID`, `SOCS`, sometimes others), store them
  in an ETS-backed jar keyed by proxy, and attach them to subsequent requests.

  ## Cookies of interest

    * `NID` — Google's preference / browsing-context cookie. Most important.
    * `SOCS` — consent state. Pre-set + refreshed by the warm-up.
    * `CONSENT` — bypass cookie, hard-coded `YES+`.
    * `__Secure-1PSID`, `__Secure-3PSID`, `SID`, `SSID`, ... — auth cookies only set if
      the visitor is logged in. We don't have them; the RPC works without them.

  ## Public API

      GmapsEx.Http.SessionStore.warm("us")           # warm the "us" pool
      GmapsEx.Http.SessionStore.cookie_header("us")  # "NID=...; SOCS=..." etc.
  """

  use GenServer

  require Logger

  @table :gmaps_ex_session_cookies
  @warmup_url "https://www.google.com/maps"
  # Cookies persist for the lifetime of the BEAM; re-warm on demand if a request
  # gets 401/403, but in practice Google's `NID` is valid for ~6 months.
  @default_pool_id "default"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns a `Cookie:`-header-shaped string for the given pool id, or `""` if
  the pool has never been warmed.

  Static cookies (`CONSENT`, `SOCS`) are always included so the caller doesn't
  need to merge headers manually.
  """
  @spec cookie_header(String.t() | nil) :: String.t()
  def cookie_header(pool_id \\ @default_pool_id) do
    pool_id = pool_id || @default_pool_id

    dynamic =
      case :ets.lookup(@table, pool_id) do
        [{^pool_id, cookies}] -> cookies
        _ -> %{}
      end

    static = %{"CONSENT" => "YES+", "SOCS" => "CAESEwgDEgk0NjI2MzkzNzkaAmVuIAEaBgiA_LyaBg"}

    static
    |> Map.merge(dynamic)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("; ")
  end

  @doc """
  Warm a session by hitting `https://www.google.com/maps?hl=...&gl=...` and
  parsing the `Set-Cookie` response headers. Returns `:ok` even if cookies were
  not found (Google sometimes serves a cached page without `Set-Cookie`).

  Safe to call concurrently — the GenServer serializes writes per pool.
  """
  @spec warm(String.t() | nil, keyword()) :: :ok
  def warm(pool_id \\ @default_pool_id, opts \\ []) do
    GenServer.call(__MODULE__, {:warm, pool_id || @default_pool_id, opts}, 30_000)
  end

  @doc """
  Merge cookies parsed from a `Set-Cookie` header list into the pool. Called by
  `Http.Client` after every response so the jar stays current.
  """
  @spec merge_set_cookies(String.t() | nil, list()) :: :ok
  def merge_set_cookies(_pool_id, []), do: :ok

  def merge_set_cookies(pool_id, headers) do
    pool_id = pool_id || @default_pool_id
    new = Enum.into(Enum.map(headers, &parse_set_cookie/1), %{}) |> Map.delete(nil)

    if new != %{} do
      GenServer.cast(__MODULE__, {:merge, pool_id, new})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:warm, pool_id, opts}, _from, state) do
    lang = Keyword.get(opts, :lang, "en")
    gl = Keyword.get(opts, :gl, "us")

    case Req.get(@warmup_url,
           params: [{"hl", lang}, {"gl", gl}],
           headers: warmup_headers(),
           receive_timeout: 15_000,
           retry: false,
           decode_body: false
         ) do
      {:ok, %Req.Response{headers: hdrs, status: status}} when status in 200..399 ->
        set_cookie_values =
          hdrs |> Enum.filter(fn {k, _} -> String.downcase(k) == "set-cookie" end)

        cookies = Enum.flat_map(set_cookie_values, fn {_, v} -> List.wrap(v) end)

        new =
          cookies
          |> Enum.map(&parse_set_cookie/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.into(%{})

        if new != %{} do
          :ets.insert(@table, {pool_id, new})

          Logger.info(
            "session warmed for #{pool_id}: #{map_size(new)} cookies (#{Enum.join(Map.keys(new), ", ")})"
          )
        else
          Logger.warning("session warm-up returned no Set-Cookie headers for #{pool_id}")
        end

        {:reply, :ok, state}

      other ->
        Logger.warning("session warm-up failed: #{inspect(other)}")
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:merge, pool_id, new}, state) do
    existing =
      case :ets.lookup(@table, pool_id) do
        [{^pool_id, c}] -> c
        _ -> %{}
      end

    :ets.insert(@table, {pool_id, Map.merge(existing, new)})
    {:noreply, state}
  end

  defp warmup_headers do
    [
      {"user-agent", "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"},
      {"accept", "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8"},
      {"accept-language", "en-US,en;q=0.9"}
    ]
  end

  defp parse_set_cookie(nil), do: nil
  defp parse_set_cookie(""), do: nil

  defp parse_set_cookie(header) when is_binary(header) do
    case String.split(header, ";", parts: 2) do
      [pair | _] ->
        case String.split(pair, "=", parts: 2) do
          [name, value] -> {String.trim(name), String.trim(value)}
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
