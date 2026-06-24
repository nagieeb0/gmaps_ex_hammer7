defmodule GmapsEx.PbBuilderTest do
  use ExUnit.Case, async: true

  alias GmapsEx.PbBuilder

  test "produces the expected key-value pairs and a non-empty pb=" do
    params =
      PbBuilder.params(%{
        query: "coffee shops",
        lat: 37.7749,
        lon: -122.4194,
        zoom: 13
      })

    assert {"tbm", "map"} in params
    assert {"authuser", "0"} in params
    assert {"hl", "en"} in params
    assert {"q", "coffee shops"} in params

    {"pb", pb} = Enum.find(params, fn {k, _} -> k == "pb" end)
    assert String.starts_with?(pb, "!4m12!1m3!1d3826.902183192154!")
    assert String.contains?(pb, "!2d-122.4194!3d37.7749!")
    assert String.contains?(pb, "!4f13.0!")
  end

  test "uses default lang when not provided" do
    params = PbBuilder.params(%{query: "x", lat: 0.0, lon: 0.0, zoom: 12})
    assert {"hl", "en"} in params
  end

  test "respects custom lang" do
    params = PbBuilder.params(%{query: "x", lat: 0.0, lon: 0.0, zoom: 12, lang: "de"})
    assert {"hl", "de"} in params
  end
end
