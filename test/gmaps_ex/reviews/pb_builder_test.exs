defmodule GmapsEx.Reviews.PbBuilderTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Reviews.PbBuilder

  test "builds the documented pb shape for the listugcposts endpoint" do
    pb = PbBuilder.params("0xAA:0xBB", "", 20, "REQID")

    # All segments present in order.
    segments = [
      "!1m6!1s0xAA:0xBB",
      "!6m4!4m1!1e1!4m1!1e3",
      "!2m2!1i20!2s",
      "!5m2!1sREQID!7e81",
      "!8m9!2b1!3b1!5b1!7b1",
      "!12m4!1b1!2b1!4m1!1e1!11m0!13m1!1e1"
    ]

    Enum.reduce(segments, -1, fn seg, prev_pos ->
      pos = :binary.match(pb, seg) |> elem(0)
      assert pos > prev_pos, "expected #{seg} to appear after the previous segment"
      pos
    end)
  end

  test "includes the page token when provided" do
    pb = PbBuilder.params("0xA:0xB", "TOKEN123", 20, "REQID")
    assert String.contains?(pb, "!2sTOKEN123!")
  end

  test "handles nil token as empty string" do
    pb = PbBuilder.params("0xA:0xB", nil, 20, "REQID")
    assert String.contains?(pb, "!2s!")
  end
end
