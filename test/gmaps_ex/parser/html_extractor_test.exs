defmodule GmapsEx.Parser.HtmlExtractorTest do
  use ExUnit.Case, async: true

  alias GmapsEx.Parser.HtmlExtractor

  defp html_with_state(state_js) do
    """
    <!DOCTYPE html><html><head><script>
    window.APP_INITIALIZATION_STATE=#{state_js};window.APP_FLAGS={};
    </script></head><body></body></html>
    """
  end

  test "extracts the prefixed JSON from section 3 index 6" do
    prefix = ")" <> "]" <> "}" <> "'"

    state_js =
      "[null,null,null,[[null,null,null,null,null,null,\"" <>
        prefix <> "[1,2,3]\"]],null,null,null]"

    html = html_with_state(state_js)
    assert {:ok, captured} = HtmlExtractor.extract(html)
    assert captured =~ "[1,2,3]"
  end

  test "returns app_state_not_found when marker is missing" do
    assert {:error, :app_state_not_found} =
             HtmlExtractor.extract("<html><body>no marker</body></html>")
  end

  test "returns place_json_not_found when section 3 has no prefixed string" do
    state_js = "[null,null,null,[[1,2,3]]]"
    html = html_with_state(state_js)
    assert {:error, :place_json_not_found} = HtmlExtractor.extract(html)
  end

  test "returns place_json_not_found when section 3 is not a list" do
    state_js = "[null,null,null,null]"
    html = html_with_state(state_js)
    assert {:error, :place_json_not_found} = HtmlExtractor.extract(html)
  end
end
