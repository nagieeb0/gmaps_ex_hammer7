defmodule GmapsEx.Parser.ReviewsTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Parser.Reviews

  defp build_indexed(pairs) do
    max = pairs |> Enum.map(&elem(&1, 0)) |> Enum.max()

    Enum.reduce(pairs, List.duplicate(nil, max + 1), fn {idx, val}, acc ->
      List.replace_at(acc, idx, val)
    end)
  end

  describe "parse_inline/1" do
    test "extracts a review with the new-shape paths" do
      el =
        List.duplicate(nil, 5)
        |> List.replace_at(
          1,
          build_indexed([
            {4, build_indexed([{5, build_indexed([{0, "Jane Doe"}, {1, "https://photo"}])}])}
          ])
        )
        |> List.replace_at(
          2,
          build_indexed([
            {0, [5]},
            {15, [["Great coffee!"]]},
            {2, [[nil, build_indexed([{6, ["https://img1"]}])]]}
          ])
        )

      wrapped = [[el]]

      [review] = Reviews.parse_inline(wrapped)
      assert review.name == "Jane Doe"
      assert review.profile_picture == "https://photo"
      assert review.rating == 5
      assert review.description == "Great coffee!"
    end

    test "ignores entries without a name" do
      el = List.duplicate(nil, 5)
      assert Reviews.parse_inline([[el]]) == []
    end

    test "returns [] on non-list input" do
      assert Reviews.parse_inline(nil) == []
      assert Reviews.parse_inline("bad") == []
    end
  end
end
