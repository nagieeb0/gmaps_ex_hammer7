defmodule GmapsEx.Output.CsvTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Output.Csv
  alias GmapsEx.Place

  @tmp_dir System.tmp_dir!()

  test "writes a header row and one row per place" do
    path = Path.join(@tmp_dir, "gmaps_ex_test_#{:rand.uniform(1_000_000)}.csv")
    on_exit(fn -> File.rm(path) end)

    places = [
      %Place{
        title: "Place A",
        category: "Coffee shop",
        latitude: 1.0,
        longitude: 2.0,
        review_rating: 4.5,
        review_count: 100
      },
      %Place{title: "Place B", category: "Restaurant"}
    ]

    :ok = Csv.write(places, path)

    content = File.read!(path)
    lines = String.split(content, "\n", trim: true)
    # header + 2 rows
    assert length(lines) == 3
    assert hd(lines) =~ "input_id"
    assert Enum.at(lines, 1) =~ "Place A"
    assert Enum.at(lines, 2) =~ "Place B"
  end
end
