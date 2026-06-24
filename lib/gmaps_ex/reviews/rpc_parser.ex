defmodule GmapsEx.Reviews.RpcParser do
  @moduledoc """
  Parses one page of `/maps/rpc/listugcposts` response.

  Response shape (after stripping `)]}'\\n` prefix):
  `[meta, next_page_token, reviews_array, ...]`

  Reviews live at `jd[2]` (sometimes `jd[0]` for older shapes). `next_page_token`
  is at `jd[1]` — empty string or `nil` means no more pages.

  Each review element uses the same field structure as the inline reviews on the
  place page, so we delegate the per-review extraction to
  `GmapsEx.Parser.Reviews`.

  Port of `extractReviews` in `gmaps/entry.go:250` + `extractNextPageToken` in
  `gmaps/reviews.go:281`.
  """

  alias GmapsEx.Parser.{Path, Reviews}

  @spec parse(binary()) :: {:ok, [map()], String.t() | nil} | {:error, term()}
  def parse(raw) when is_binary(raw) do
    body =
      raw
      |> String.trim_leading(")]}'")
      |> String.trim_leading()

    case Jason.decode(body) do
      {:ok, jd} when is_list(jd) and length(jd) >= 2 ->
        token = next_page_token(jd)
        reviews_i = locate_reviews(jd)
        {:ok, Reviews.parse_inline(reviews_i), token}

      {:ok, _} ->
        {:error, :unexpected_shape}

      {:error, _} = err ->
        err
    end
  end

  defp next_page_token(jd) do
    case Path.get(jd, [1]) do
      tok when is_binary(tok) -> tok
      _ -> nil
    end
  end

  defp locate_reviews(jd) do
    case Path.get(jd, [2]) do
      list when is_list(list) and list != [] -> list
      _ -> Path.get(jd, [0], :list, [])
    end
  end
end
