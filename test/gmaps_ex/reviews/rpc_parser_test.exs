defmodule GmapsEx.Reviews.RpcParserTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Reviews.RpcParser

  defp build_indexed(pairs) do
    max = pairs |> Enum.map(&elem(&1, 0)) |> Enum.max()

    Enum.reduce(pairs, List.duplicate(nil, max + 1), fn {idx, val}, acc ->
      List.replace_at(acc, idx, val)
    end)
  end

  test "extracts reviews from index [2] and the next-page token from [1]" do
    review_el =
      List.duplicate(nil, 5)
      |> List.replace_at(
        1,
        build_indexed([
          {4,
           build_indexed([
             {5, build_indexed([{0, "Sam Smith"}, {1, "https://photo.jpg"}])}
           ])}
        ])
      )
      |> List.replace_at(
        2,
        build_indexed([
          {0, [5]},
          {15, [["Excellent service"]]}
        ])
      )

    body = Jason.encode!([%{}, "NEXT_TOKEN", [[review_el]]])
    raw = ")]}'\n" <> body

    assert {:ok, [review], "NEXT_TOKEN"} = RpcParser.parse(raw)
    assert review.name == "Sam Smith"
    assert review.rating == 5
    assert review.description == "Excellent service"
  end

  test "returns nil token when index [1] is null" do
    body = Jason.encode!([%{}, nil, []])
    assert {:ok, [], nil} = RpcParser.parse(")]}'\n" <> body)
  end

  test "falls back to index [0] when [2] is empty" do
    review_el =
      List.duplicate(nil, 5)
      |> List.replace_at(
        1,
        build_indexed([
          {4, build_indexed([{5, build_indexed([{0, "Fallback Author"}])}])}
        ])
      )
      |> List.replace_at(2, build_indexed([{0, [4]}]))

    body = Jason.encode!([[[review_el]], "TOKEN_X", []])
    assert {:ok, [review], "TOKEN_X"} = RpcParser.parse(")]}'\n" <> body)
    assert review.name == "Fallback Author"
  end

  test "rejects malformed responses" do
    assert {:error, :unexpected_shape} = RpcParser.parse(")]}'\n" <> Jason.encode!(%{}))
    assert {:error, _} = RpcParser.parse(")]}'\nnot json")
  end
end
