defmodule GmapsEx.Parser.PlaceTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Parser.Place

  defp build_indexed(pairs) do
    max = pairs |> Enum.map(&elem(&1, 0)) |> Enum.max()

    Enum.reduce(pairs, List.duplicate(nil, max + 1), fn {idx, val}, acc ->
      List.replace_at(acc, idx, val)
    end)
  end

  defp build_darray(overrides) do
    base = List.duplicate(nil, 260)

    Enum.reduce(overrides, base, fn {idx, val}, acc -> List.replace_at(acc, idx, val) end)
  end

  describe "parse/1" do
    test "extracts all the expected fields from a representative shape" do
      darray =
        build_darray(%{
          27 => "https://maps.google.com/?cid=12345",
          11 => "Blue Bottle Coffee",
          13 => ["Coffee shop", "Cafe"],
          18 => "Blue Bottle Coffee, 315 Linden St, San Francisco, CA 94102",
          4 => build_indexed([{7, 4.6}, {8, 682}]),
          37 => build_indexed([{1, 682}]),
          9 => build_indexed([{2, 37.7766}, {3, -122.4232}]),
          178 => [["(510) 661-3510"]],
          7 => ["https://bluebottlecoffee.com"],
          10 => "data-id-1",
          78 => "place-id-1",
          30 => "America/Los_Angeles",
          175 => build_indexed([{3, [10, 20, 50, 200, 400]}])
        })

      jd = List.duplicate(nil, 30) |> List.replace_at(6, darray)
      raw = Jason.encode!(jd)

      assert {:ok, place} = Place.parse(raw)
      assert place.title == "Blue Bottle Coffee"
      assert place.categories == ["Coffee shop", "Cafe"]
      assert place.category == "Coffee shop"
      assert place.review_rating == 4.6
      assert place.review_count == 682
      assert place.latitude == 37.7766
      assert place.longitude == -122.4232
      assert place.phone == "(510) 661-3510"
      assert place.website == "https://bluebottlecoffee.com"
      assert place.data_id == "data-id-1"
      assert place.place_id == "place-id-1"
      assert place.timezone == "America/Los_Angeles"

      assert place.reviews_per_rating == %{
               "1" => 10,
               "2" => 20,
               "3" => 50,
               "4" => 200,
               "5" => 400
             }

      assert place.address =~ "Linden"
    end

    test "review_count falls back to legacy [4, 8] when [37, 1] is absent" do
      darray =
        build_darray(%{
          11 => "Old Place",
          4 => build_indexed([{7, 4.0}, {8, 123}])
        })

      jd = List.duplicate(nil, 30) |> List.replace_at(6, darray)
      assert {:ok, place} = Place.parse(Jason.encode!(jd))
      assert place.review_count == 123
    end

    test "returns :invalid_json on bad input" do
      assert {:error, _} = Place.parse("not json")
    end

    test "returns :invalid_json when outer array is too short" do
      assert {:error, :invalid_json} = Place.parse(Jason.encode!([nil, nil]))
    end

    test "handles missing optional fields without crashing" do
      darray = build_darray(%{11 => "Minimal Place"})
      jd = List.duplicate(nil, 30) |> List.replace_at(6, darray)
      assert {:ok, place} = Place.parse(Jason.encode!(jd))
      assert place.title == "Minimal Place"
      assert place.review_count == 0
      assert place.categories == []
      assert place.images == []
      assert place.reservations == []
    end
  end
end
