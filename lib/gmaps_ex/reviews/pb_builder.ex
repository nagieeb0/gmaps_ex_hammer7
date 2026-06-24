defmodule GmapsEx.Reviews.PbBuilder do
  @moduledoc """
  Builds the `pb=` parameter for `/maps/rpc/listugcposts`.

  Port of `generateURL` in `google-maps-scraper-main/gmaps/reviews.go:235-261`.

  ## pb= shape (Dec 2025 / current)

      !1m6!1s{place_id}
      !6m4!4m1!1e1!4m1!1e3
      !2m2!1i{page_size}!2s{page_token}
      !5m2!1s{request_id}!7e81
      !8m9!2b1!3b1!5b1!7b1
      !12m4!1b1!2b1!4m1!1e1!11m0!13m1!1e1

  `place_id` here is what we call `data_id` everywhere else — Google's stable
  feature identifier (`0x...:0x...`).
  """

  @spec params(String.t(), String.t(), integer(), String.t()) :: String.t()
  def params(data_id, page_token, page_size, request_id) do
    # Return the *raw* pb string. The HTTP client URL-encodes it once when
    # serializing query params. Pre-encoding `:` → `%3A` here would lead to
    # double encoding (`%3A` → `%253A`) which Google rejects with 400.
    IO.iodata_to_binary([
      "!1m6!1s",
      data_id,
      "!6m4!4m1!1e1!4m1!1e3",
      "!2m2!1i",
      Integer.to_string(page_size),
      "!2s",
      page_token || "",
      "!5m2!1s",
      request_id,
      "!7e81",
      "!8m9!2b1!3b1!5b1!7b1",
      "!12m4!1b1!2b1!4m1!1e1!11m0!13m1!1e1"
    ])
  end
end
