defmodule GmapsEx.Parser.Reviews do
  @moduledoc """
  Parses inline reviews from a place-detail darray.

  Port of `parseReviews` in `gmaps/entry.go:455-544`. Google has shipped multiple
  structures over the years; the Go code uses multi-path fallbacks and so do we.
  """

  alias GmapsEx.Parser.Path

  @spec parse_inline(list()) :: [map()]
  def parse_inline(reviews_i) when is_list(reviews_i) do
    reviews_i
    |> Enum.with_index()
    |> Enum.flat_map(fn {_, i} ->
      el =
        case Path.get(reviews_i, [i, 0], :list) do
          list when is_list(list) and list != [] -> list
          _ -> Path.get(reviews_i, [i], :list, [])
        end

      case build(el) do
        nil -> []
        review -> [review]
      end
    end)
  end

  def parse_inline(_), do: []

  defp build(el) when is_list(el) do
    name = Path.first_of(el, [[1, 4, 5, 0], [1, 4, 4], [0, 1]])

    if is_binary(name) and name != "" do
      %{
        name: name,
        profile_picture: profile_picture(el),
        rating: rating(el),
        description: description(el),
        when: when_str(el),
        images: images(el)
      }
    end
  end

  defp build(_), do: nil

  defp profile_picture(el) do
    Path.first_of(el, [[1, 4, 5, 1], [1, 2, 0], [0, 2, 0]]) || ""
  end

  defp rating(el) do
    val = Path.first_of(el, [[2, 0, 0], [2, 0], [1, 0, 0]])

    cond do
      is_integer(val) -> val
      is_float(val) -> trunc(val)
      true -> 0
    end
  end

  defp description(el) do
    Path.first_of(el, [[2, 15, 0, 0], [2, 15, 0], [3, 0]]) || ""
  end

  defp when_str(el) do
    case Path.first_of(el, [[2, 2, 0, 1, 21, 6, 8], [2, 2, 0, 1, 6, 8]]) do
      [y, m, d | _] -> "#{y}-#{m}-#{d}"
      _ -> ""
    end
  end

  defp images(el) do
    el
    |> Path.get([2, 2], :list, [])
    |> Enum.with_index()
    |> Enum.flat_map(fn {img, idx} ->
      case Path.get(el, [2, 2, idx, 1, 6, 0]) do
        url when is_binary(url) and url != "" ->
          [url]

        _ ->
          _ = img
          []
      end
    end)
  end
end
