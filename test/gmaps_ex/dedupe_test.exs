defmodule GmapsEx.DedupeTest do
  use ExUnit.Case, async: false

  alias GmapsEx.Dedupe

  setup do
    case Process.whereis(Dedupe) do
      nil -> {:ok, _} = Dedupe.start_link()
      _ -> :ok
    end

    Dedupe.reset()
    :ok
  end

  test "first call returns true; second returns false" do
    assert Dedupe.add_if_not_exists("key-1") == true
    assert Dedupe.add_if_not_exists("key-1") == false
  end

  test "different keys are independent" do
    assert Dedupe.add_if_not_exists("a") == true
    assert Dedupe.add_if_not_exists("b") == true
    assert Dedupe.add_if_not_exists("a") == false
    assert Dedupe.add_if_not_exists("b") == false
  end

  test "reset wipes everything" do
    Dedupe.add_if_not_exists("x")
    Dedupe.reset()
    assert Dedupe.add_if_not_exists("x") == true
  end
end
