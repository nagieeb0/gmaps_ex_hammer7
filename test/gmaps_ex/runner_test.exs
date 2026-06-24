defmodule GmapsEx.RunnerTest do
  use GmapsEx.DataCase, async: true

  alias GmapsEx.Runner

  describe "grid_seeds/3" do
    test "splits a bbox into cell-sized seeds" do
      seeds = Runner.grid_seeds("coffee", {37.7, -122.5, 37.85, -122.35}, 5.0, zoom: 13)

      assert length(seeds) >= 1
      assert Enum.all?(seeds, &(&1.query == "coffee"))
      assert Enum.all?(seeds, &(&1.zoom == 13))

      [first | _] = seeds
      assert first.lat >= 37.7 and first.lat <= 37.85
      assert first.lon >= -122.5 and first.lon <= -122.35
    end

    test "propagates lang and gl to every seed" do
      seeds =
        Runner.grid_seeds("cafe", {48.8, 2.3, 48.9, 2.4}, 2.0,
          lang: "fr",
          gl: "fr"
        )

      assert Enum.all?(seeds, &(&1.lang == "fr"))
      assert Enum.all?(seeds, &(&1.gl == "fr"))
    end

    test "uses sensible defaults" do
      [seed | _] = Runner.grid_seeds("x", {0.0, 0.0, 0.1, 0.1}, 5.0)
      assert seed.lang == "en"
      assert seed.gl == "us"
      assert seed.zoom == 13
    end
  end
end
