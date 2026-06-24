defmodule GmapsEx.Parser.PathTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Parser.Path

  test "walks nested lists by index" do
    assert Path.get([[1, [2, 3]]], [0, 1, 1]) == 3
  end

  test "returns nil on out-of-range index" do
    assert Path.get([[1, [2, 3]]], [0, 5]) == nil
  end

  test "returns nil on non-list intermediate" do
    assert Path.get([1, 2, 3], [0, 0]) == nil
  end

  test "casts to int and float" do
    assert Path.get([3.7], [0], :int) == 3
    assert Path.get([3], [0], :float) == 3.0
  end

  test "uses default on missing path" do
    assert Path.get([1, 2], [5], :int, 0) == 0
    assert Path.get([1, 2], [5], :list, []) == []
  end

  test "first_of returns first non-nil/non-empty value" do
    data = [[nil, "", "hit", "miss"]]
    assert Path.first_of(data, [[0, 0], [0, 1], [0, 2]]) == "hit"
  end

  test "first_of falls through to nil when all paths miss" do
    assert Path.first_of([1, 2], [[5], [10]]) == nil
  end
end
