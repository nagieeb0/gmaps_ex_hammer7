defmodule GmapsEx.Http.ProxyPool do
  @moduledoc """
  Round-robin proxy rotation. Marks proxies dead on 5xx/timeout; revives after a backoff.

  Configured via `:gmaps_ex, GmapsEx.Http.ProxyPool, proxies: [...]`. Each proxy is a string
  in Webshare's `host:port:user:pass` format (see `webshare.md` in the Go scraper). An empty
  list disables proxying — useful for development and CI.
  """

  use GenServer

  require Logger

  @table :gmaps_ex_proxy_pool
  @revive_after_ms 5 * 60_000

  defstruct [:proxies, :index, :dead_until]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the next live proxy as a URI map, or `nil` if the pool is empty / all dead.
  """
  @spec checkout() :: map() | nil
  def checkout do
    GenServer.call(__MODULE__, :checkout)
  end

  @doc "Marks a proxy dead until it's revived by the timeout."
  @spec mark_dead(map()) :: :ok
  def mark_dead(%{} = proxy) do
    GenServer.cast(__MODULE__, {:mark_dead, proxy})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    proxies =
      :gmaps_ex
      |> Application.get_env(GmapsEx.Http.ProxyPool, [])
      |> Keyword.get(:proxies, [])
      |> Enum.map(&parse/1)
      |> Enum.reject(&is_nil/1)

    Logger.info("ProxyPool started with #{length(proxies)} proxies")
    {:ok, %__MODULE__{proxies: proxies, index: 0, dead_until: %{}}}
  end

  @impl true
  def handle_call(:checkout, _from, %{proxies: []} = state), do: {:reply, nil, state}

  def handle_call(:checkout, _from, state) do
    now = System.monotonic_time(:millisecond)
    live = Enum.reject(state.proxies, &(Map.get(state.dead_until, &1.id, 0) > now))

    case live do
      [] ->
        {:reply, nil, state}

      live ->
        idx = rem(state.index, length(live))
        {:reply, Enum.at(live, idx), %{state | index: state.index + 1}}
    end
  end

  @impl true
  def handle_cast({:mark_dead, proxy}, state) do
    until = System.monotonic_time(:millisecond) + @revive_after_ms
    {:noreply, %{state | dead_until: Map.put(state.dead_until, proxy.id, until)}}
  end

  # "host:port:user:pass" (Webshare) or "http://user:pass@host:port" or "host:port"
  defp parse("http" <> _ = url) do
    uri = URI.parse(url)

    %{
      id: url,
      scheme: uri.scheme,
      host: uri.host,
      port: uri.port,
      userinfo: uri.userinfo
    }
  end

  defp parse(str) when is_binary(str) do
    case String.split(str, ":") do
      [host, port, user, pass] ->
        %{
          id: str,
          scheme: "http",
          host: host,
          port: String.to_integer(port),
          userinfo: "#{user}:#{pass}"
        }

      [host, port] ->
        %{id: str, scheme: "http", host: host, port: String.to_integer(port), userinfo: nil}

      _ ->
        nil
    end
  end

  defp parse(_), do: nil
end
