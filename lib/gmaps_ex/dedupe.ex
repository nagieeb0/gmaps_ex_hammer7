defmodule GmapsEx.Dedupe do
  @moduledoc """
  Per-run ETS-backed dedupe. Mirrors `deduper/hashmap.go` in the Go scraper but uses
  Erlang's :ets table instead of a Go map+RWMutex. Keyed on place URL (the Go side
  hashes with FNV-64; ETS lookups are already O(1) by key string).
  """

  use GenServer

  @table :gmaps_ex_dedupe

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns true if newly added; false if already seen."
  @spec add_if_not_exists(String.t()) :: boolean()
  def add_if_not_exists(key) when is_binary(key) do
    :ets.insert_new(@table, {key, true})
  end

  @doc "Clears all entries — call this at the start of a new run."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
