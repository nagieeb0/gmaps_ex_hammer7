defmodule GmapsEx.Parser.HtmlExtractor do
  @moduledoc """
  Pulls the place-detail JSON out of a Google Maps HTML page.

  The Go scraper runs JS in a headless browser to read
  `window.APP_INITIALIZATION_STATE[3]` after page load (`gmaps/place.go:297-319`).
  That same value is also present in the initial HTML response — Google
  pre-renders it into a `<script>` tag. We:

    1. Locate the `window.APP_INITIALIZATION_STATE=` marker.
    2. Scan forward counting `[` / `]` brackets (with string-aware escape handling)
       to find the matching closing bracket of the top-level array.
    3. JSON-decode that slice.
    4. Walk to `[3]` and find the `)]}'`-prefixed inner string at index 6 or 5.

  Returns the inner `)]}'`-prefixed JSON ready for `GmapsEx.Parser.Place`.
  """

  @marker "window.APP_INITIALIZATION_STATE="

  @spec extract(binary()) :: {:ok, binary()} | {:error, atom()}
  def extract(html) when is_binary(html) do
    with {:ok, state_json} <- slice_top_level_array(html),
         {:ok, decoded} <- Jason.decode(state_json),
         {:ok, place_json} <- locate_place_json(decoded) do
      {:ok, place_json}
    end
  end

  defp slice_top_level_array(html) do
    case :binary.match(html, @marker) do
      :nomatch ->
        {:error, :app_state_not_found}

      {pos, _len} ->
        start = pos + byte_size(@marker)

        case scan_balanced_array(html, start) do
          {:ok, json} -> {:ok, json}
          err -> err
        end
    end
  end

  defp scan_balanced_array(html, start) do
    case binary_part(html, start, 1) do
      "[" -> do_scan(html, start, start + 1, 1, false, nil)
      _ -> {:error, :app_state_malformed}
    end
  end

  # depth=0 means we just closed the top-level array → return slice
  defp do_scan(html, start, pos, 0, _in_str, _prev) do
    {:ok, binary_part(html, start, pos - start)}
  end

  defp do_scan(html, start, pos, depth, in_str, prev) do
    if pos >= byte_size(html) do
      {:error, :app_state_unterminated}
    else
      <<c>> = binary_part(html, pos, 1)

      cond do
        in_str and c == ?\\ and prev != ?\\ ->
          do_scan(html, start, pos + 1, depth, in_str, ?\\)

        in_str and c == ?" and prev != ?\\ ->
          do_scan(html, start, pos + 1, depth, false, c)

        in_str ->
          do_scan(html, start, pos + 1, depth, in_str, c)

        c == ?" ->
          do_scan(html, start, pos + 1, depth, true, c)

        c == ?[ ->
          do_scan(html, start, pos + 1, depth + 1, in_str, c)

        c == ?] ->
          do_scan(html, start, pos + 1, depth - 1, in_str, c)

        true ->
          do_scan(html, start, pos + 1, depth, in_str, c)
      end
    end
  end

  defp locate_place_json(state) do
    case Enum.at(state, 3) do
      list when is_list(list) -> scan_section(list)
      _ -> {:error, :place_json_not_found}
    end
  end

  defp scan_section(section) do
    section
    |> Enum.find_value(fn arr ->
      case arr do
        list when is_list(list) -> pick_prefixed(list)
        _ -> nil
      end
    end)
    |> case do
      nil -> {:error, :place_json_not_found}
      str -> {:ok, str |> String.trim_leading(")]}'") |> String.trim_leading()}
    end
  end

  defp pick_prefixed(arr) do
    Enum.find_value([6, 5], fn idx ->
      case Enum.at(arr, idx) do
        val when is_binary(val) ->
          if String.starts_with?(val, ")]}'"), do: val, else: nil

        _ ->
          nil
      end
    end)
  end
end
