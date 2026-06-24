defmodule GmapsEx.Reviews do
  @moduledoc """
  Paginated review fetcher for one place.

  ## ⚠ Known limitation (verified 2026-05-22)

  Google's `/maps/rpc/listugcposts` endpoint returns `[null, null, null, null, null, 1]`
  (empty/auth-rejected) for unauthenticated HTTP requests, even with the
  `NID`/`SOCS`/`CONSENT` cookies harvested by `GmapsEx.Http.SessionStore`. The
  Go scraper sidesteps this by running the RPC from inside a Playwright browser
  context (see `gmaps/reviews.go:64-128`, and their own code comment: *"may
  fail due to lack of authentication"*).

  Pure HTTP appears insufficient — likely the endpoint TLS-fingerprints or
  requires a JS-derived token. The code is kept here for the day someone wires
  a real browser session (or finds another workaround).

  **In production right now**, the `~10 inline reviews` per place that
  `GmapsEx.Parser.Place` extracts from the place-detail XHR are persisted
  automatically by `Workers.PlaceWorker`. That's enough for sentiment sampling
  on most places. For comprehensive review extraction on popular places
  (>100 reviews), use the Go scraper or add a Playwright fallback worker.

  ## Public API (preserved for future use)

      iex> {:ok, reviews} = GmapsEx.Reviews.fetch_all("0x80858098babc2d4b:0xbeedd659cc698c92")
      {:ok, []}   # see limitation above

  ## Options

    * `:lang` (default `"en"`)
    * `:gl` (default `"us"`)
    * `:page_size` (default `20`)
    * `:max_pages` (default `100`)
    * `:sleep_ms` (default `0`)
  """

  alias GmapsEx.Http.Client
  alias GmapsEx.Reviews.{PbBuilder, RpcParser}

  require Logger

  @rpc_url "https://www.google.com/maps/rpc/listugcposts"

  @type review :: %{
          name: String.t() | nil,
          rating: integer(),
          description: String.t() | nil,
          when: String.t() | nil,
          profile_picture: String.t() | nil,
          images: [String.t()]
        }

  @spec fetch_all(String.t(), keyword()) :: {:ok, [review()]} | {:error, term()}
  def fetch_all(data_id, opts \\ []) when is_binary(data_id) do
    page_size = Keyword.get(opts, :page_size, 20)
    max_pages = Keyword.get(opts, :max_pages, 100)
    lang = Keyword.get(opts, :lang, "en")
    gl = Keyword.get(opts, :gl, "us")
    sleep_ms = Keyword.get(opts, :sleep_ms, 0)
    request_id = generate_request_id(21)

    fetch_loop(
      data_id,
      _token = "",
      _pages_so_far = 0,
      _acc = [],
      max_pages: max_pages,
      page_size: page_size,
      request_id: request_id,
      lang: lang,
      gl: gl,
      sleep_ms: sleep_ms
    )
  end

  defp fetch_loop(data_id, token, pages, acc, opts) do
    if pages >= opts[:max_pages] do
      {:ok, Enum.reverse(acc)}
    else
      do_fetch(data_id, token, pages, acc, opts)
    end
  end

  defp do_fetch(data_id, token, pages, acc, opts) do
    pb = PbBuilder.params(data_id, token, opts[:page_size], opts[:request_id])

    case Client.get(@rpc_url,
           params: [{"authuser", "0"}, {"hl", opts[:lang]}, {"gl", opts[:gl]}, {"pb", pb}]
         ) do
      {:ok, body, _headers} ->
        case RpcParser.parse(body) do
          {:ok, reviews, next_token} ->
            acc = Enum.reduce(reviews, acc, fn r, a -> [r | a] end)

            if next_token in [nil, ""] do
              {:ok, Enum.reverse(acc)}
            else
              if opts[:sleep_ms] > 0, do: Process.sleep(opts[:sleep_ms])
              fetch_loop(data_id, next_token, pages + 1, acc, opts)
            end

          {:error, reason} when pages > 0 ->
            Logger.warning("reviews page parse error after #{pages} pages: #{inspect(reason)}")
            {:ok, Enum.reverse(acc)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} when pages > 0 ->
        Logger.warning("reviews page fetch error after #{pages} pages: #{inspect(reason)}")
        {:ok, Enum.reverse(acc)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Mirrors `generateRandomID` in the Go scraper — a base64-url-safe token used
  # as a session identifier on every page request for one place.
  defp generate_request_id(length) do
    num_bytes = max(div(length * 6 + 7, 8), 16)

    :crypto.strong_rand_bytes(num_bytes)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end
end
