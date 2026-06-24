defmodule GmapsEx.ExiterTest do
  use ExUnit.Case, async: false

  alias GmapsEx.Exiter

  setup do
    case Process.whereis(Exiter) do
      nil -> {:ok, _} = Exiter.start_link()
      _ -> :ok
    end

    Exiter.reset()
    :ok
  end

  test "tracks counts independently" do
    Exiter.set_seed_count(3)
    Exiter.incr_places_found(5)
    Exiter.incr_seed_completed(1)
    Process.sleep(20)

    stats = Exiter.stats()
    assert stats.seed_count == 3
    assert stats.seed_completed == 1
    assert stats.places_found == 5
  end

  test "emits :run_complete telemetry when balanced" do
    :telemetry.attach(
      "exiter-test",
      [:gmaps_ex, :run, :complete],
      fn _, m, _, parent -> send(parent, {:done, m}) end,
      self()
    )

    Exiter.set_seed_count(1)
    Exiter.incr_places_found(2)
    Exiter.incr_seed_completed()
    Exiter.incr_places_completed(2)

    assert_receive {:done, %{seeds: 1, places: 2}}, 500
    :telemetry.detach("exiter-test")
  end

  test "does not emit twice" do
    :telemetry.attach(
      "exiter-test-once",
      [:gmaps_ex, :run, :complete],
      fn _, _, _, parent -> send(parent, :done) end,
      self()
    )

    Exiter.set_seed_count(1)
    Exiter.incr_seed_completed()
    assert_receive :done, 500

    Exiter.incr_seed_completed()
    refute_receive :done, 100
    :telemetry.detach("exiter-test-once")
  end
end
