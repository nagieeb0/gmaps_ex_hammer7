defmodule GmapsEx.Exiter do
  @moduledoc """
  Counts seeds and places to detect run completion. Mirrors `exiter/` in the Go scraper.

  A run is complete when `seed_completed >= seed_count` AND `places_completed >= places_found`.
  Emits a `[:gmaps_ex, :run, :complete]` telemetry event when the condition is reached.
  """

  use GenServer

  require Logger

  defstruct seed_count: 0,
            seed_completed: 0,
            places_found: 0,
            places_completed: 0,
            signaled: false

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def set_seed_count(n), do: GenServer.cast(__MODULE__, {:set_seed_count, n})
  def incr_seed_completed(n \\ 1), do: GenServer.cast(__MODULE__, {:incr_seed_completed, n})
  def incr_places_found(n \\ 1), do: GenServer.cast(__MODULE__, {:incr_places_found, n})
  def incr_places_completed(n \\ 1), do: GenServer.cast(__MODULE__, {:incr_places_completed, n})
  def stats, do: GenServer.call(__MODULE__, :stats)
  def reset, do: GenServer.cast(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast(:reset, _state), do: {:noreply, %__MODULE__{}}

  def handle_cast({:set_seed_count, n}, state), do: {:noreply, %{state | seed_count: n}}

  def handle_cast({:incr_seed_completed, n}, state),
    do: check(%{state | seed_completed: state.seed_completed + n})

  def handle_cast({:incr_places_found, n}, state),
    do: check(%{state | places_found: state.places_found + n})

  def handle_cast({:incr_places_completed, n}, state),
    do: check(%{state | places_completed: state.places_completed + n})

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, Map.from_struct(state), state}

  defp check(state) do
    if not state.signaled and state.seed_count > 0 and
         state.seed_completed >= state.seed_count and
         state.places_completed >= state.places_found do
      :telemetry.execute([:gmaps_ex, :run, :complete], %{
        seeds: state.seed_count,
        places: state.places_completed
      })

      Logger.info("run_complete: #{state.places_completed} places, #{state.seed_count} seeds")
      {:noreply, %{state | signaled: true}}
    else
      {:noreply, state}
    end
  end
end
