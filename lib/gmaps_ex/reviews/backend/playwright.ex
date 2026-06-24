defmodule GmapsEx.Reviews.Backend.Playwright do
  # Opt-in dependency — `Playwright.*` symbols are resolved at runtime
  # via `Code.ensure_loaded?/1` in the Chain dispatcher; the compiler
  # doesn't need to warn about them.
  @compile {:no_warn_undefined,
            [Playwright, Playwright.Browser, Playwright.Page, Playwright.BrowserContext]}

  @moduledoc """
  Reviews backend backed by [Playwright Elixir](https://github.com/mechanical-orchard/playwright-elixir).
  The production-grade browser fallback — same trick the Go scraper uses to
  fetch the review-RPC endpoint with real browser-session cookies.

  ## ⚠ Opt-in dependency

  Add to your host app:

      def deps do
        [
          {:gmaps_ex, "~> 0.1"},
          {:playwright, "~> 1.49"}
        ]
      end

  Then install Chromium (one-time, ~200 MB):

      mix playwright.install chromium

  ## How it works

  This is the same approach as `gmaps/reviews.go:104-128` in the Go scraper —
  the **only** way to reliably hit `/maps/rpc/listugcposts` is to call it
  from inside a real browser context that has Google's session cookies.

  1. Launch Chromium headless (or stealth-Firefox if you configure it).
  2. Navigate to the place URL. Browser receives + stores Google's cookies.
  3. From inside the page, `fetch('/maps/rpc/listugcposts?…', { credentials: 'include' })`
     authenticates with the just-acquired cookies.
  4. Parse the `)]}'`-prefixed JSON response via `GmapsEx.Reviews.RpcParser`.
  5. Paginate using the `next_page_token` until no more, or `max_pages` reached.

  ## Performance

  Per-place cost: ~5–10 seconds (browser launch + navigate + N RPC pages).
  Run with concurrency 4–8 on a single 4-vCPU machine.

  ## Configuration knobs

      config :gmaps_ex, GmapsEx.Reviews.Backend.Playwright,
        browser: :chromium,         # or :firefox
        max_pages: 50,              # up to 50 × 20 = 1000 reviews per place
        page_size: 20,
        navigation_timeout_ms: 30_000,
        rpc_timeout_ms: 15_000
  """

  @behaviour GmapsEx.Reviews.Backend

  require Logger

  alias GmapsEx.Reviews.{PbBuilder, RpcParser}

  @impl true
  def fetch_all(data_id, opts) do
    if not Code.ensure_loaded?(Playwright) do
      {:error, :playwright_not_installed}
    else
      lang = opts[:lang] || "en"
      gl = opts[:gl] || "us"
      max_pages = opts[:max_pages] || cfg(:max_pages, 50)
      page_size = cfg(:page_size, 20)

      try do
        do_fetch(data_id, lang, gl, max_pages, page_size)
      rescue
        e ->
          Logger.error("Playwright reviews fetch raised for #{data_id}: #{inspect(e)}")
          {:error, :exception}
      end
    end
  end

  # The actual implementation. Pseudo-coded against playwright-elixir's API —
  # adjust the exact module calls to match your installed version.
  defp do_fetch(data_id, lang, gl, max_pages, page_size) do
    {:ok, browser} = Playwright.launch(cfg(:browser, :chromium))
    page = Playwright.Browser.new_page(browser)

    place_url =
      "https://www.google.com/maps/place/?ftid=#{data_id}&hl=#{lang}&gl=#{gl}"

    :ok =
      Playwright.Page.goto(page, place_url, timeout: cfg(:navigation_timeout_ms, 30_000))

    # Browser context now has the cookies. Generate a session-scoped request
    # ID (mirrors gmaps/reviews.go:47).
    request_id =
      :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false) |> binary_part(0, 21)

    reviews = paginate_reviews(page, data_id, request_id, "", page_size, max_pages, [])
    Playwright.Page.close(page)
    Playwright.Browser.close(browser)
    {:ok, reviews}
  end

  defp paginate_reviews(_page, _data_id, _req_id, _token, _size, max, acc) when max <= 0,
    do: Enum.reverse(acc)

  defp paginate_reviews(page, data_id, req_id, token, size, max, acc) do
    pb = PbBuilder.params(data_id, token, size, req_id)

    # Run the RPC fetch INSIDE the browser so it inherits cookies.
    js = """
      async () => {
        const r = await fetch(
          '/maps/rpc/listugcposts?authuser=0&hl=en&gl=us&pb=' + encodeURIComponent(#{Jason.encode!(pb)}),
          { credentials: 'include', headers: { Accept: '*/*' } }
        );
        if (!r.ok) return { error: 'HTTP ' + r.status };
        return { data: await r.text() };
      }
    """

    case Playwright.Page.evaluate(page, js) do
      %{"data" => raw} ->
        case RpcParser.parse(raw) do
          {:ok, batch, next_token} when next_token in [nil, ""] ->
            Enum.reverse(acc ++ batch)

          {:ok, batch, next_token} ->
            paginate_reviews(page, data_id, req_id, next_token, size, max - 1, acc ++ batch)

          {:error, _} ->
            Enum.reverse(acc)
        end

      _ ->
        Enum.reverse(acc)
    end
  end

  defp cfg(key, default) do
    Application.get_env(:gmaps_ex, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
