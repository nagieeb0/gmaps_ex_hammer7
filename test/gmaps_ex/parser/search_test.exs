defmodule GmapsEx.Parser.SearchTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Parser.Search

  test "extracts title, categories, lat/lon from a synthetic response" do
    business =
      List.duplicate(nil, 200)
      |> List.replace_at(0, "input-id-1")
      |> List.replace_at(11, "Sightglass Coffee")
      |> List.replace_at(13, ["Coffee shop", "Roastery"])
      |> List.replace_at(7, ["https://sightglasscoffee.com"])
      |> List.replace_at(4, build_indexed([{7, 4.5}, {8, 1234}]))
      |> List.replace_at(2, ["270 7th St", "San Francisco", "CA"])
      |> List.replace_at(9, build_indexed([{2, 37.7766}, {3, -122.4081}]))
      |> List.replace_at(178, [["+1 415-861-1313"]])
      |> List.replace_at(34, build_indexed([{4, build_indexed([{4, "Open"}])}]))
      |> List.replace_at(30, "America/Los_Angeles")
      |> List.replace_at(10, "data-id-1")

    item = List.duplicate(nil, 15) |> List.replace_at(14, business)

    container = [nil, [nil, item, item]]

    raw = Jason.encode!([container])

    assert {:ok, [a, b]} = Search.parse(raw)
    assert a.title == "Sightglass Coffee"
    assert a.categories == ["Coffee shop", "Roastery"]
    assert a.website == "https://sightglasscoffee.com"
    assert a.review_rating == 4.5
    assert a.review_count == 1234
    assert a.latitude == 37.7766
    assert a.longitude == -122.4081
    assert a.phone == "+1415-861-1313"
    assert a.address == "270 7th St, San Francisco, CA"
    assert a.status == "Open"
    assert a.timezone == "America/Los_Angeles"
    assert a.data_id == "data-id-1"
    assert b.title == "Sightglass Coffee"
  end

  test "returns error on malformed JSON" do
    assert {:error, _} = Search.parse("not json")
  end

  defp build_indexed(pairs) do
    max = pairs |> Enum.map(&elem(&1, 0)) |> Enum.max()

    Enum.reduce(pairs, List.duplicate(nil, max + 1), fn {idx, val}, acc ->
      List.replace_at(acc, idx, val)
    end)
  end
end
