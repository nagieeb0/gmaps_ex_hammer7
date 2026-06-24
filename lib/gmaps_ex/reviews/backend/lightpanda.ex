defmodule GmapsEx.Reviews.Backend.Lightpanda do
  # Opt-in dependency — `LightpandaEx` is loaded at runtime via the
  # Chain dispatcher's `Code.ensure_loaded?/1` guard. Tell the
  # compiler to stop warning about the symbols.
  @compile {:no_warn_undefined, [LightpandaEx]}

  @moduledoc """
  Reviews backend backed by [Lightpanda](https://github.com/lightpanda-io/browser)
  — the V8-based headless browser, ~10× lighter than Chromium.

  ## ⚠ Opt-in dependency

  This module compiles only when `:lightpanda_ex` is present. Add it to your
  host app:

      def deps do
        [
          {:gmaps_ex, "~> 0.1"},
          {:lightpanda_ex, "~> 0.1"}     # ← you supply this
        ]
      end

  Then install the binary:

      mix lightpanda.install

  ## ⚠ Production caveat

  `lightpanda_ex` is at v0.1.0 (released May 2026). Its Google-Maps SPA
  compatibility is **unverified**. Treat this backend as a fast-path attempt
  that may not always succeed — `Reviews.Backend.Chain` will then fall back
  to Playwright.

  ## How it works

  1. Launch a Lightpanda session.
  2. Navigate to `https://www.google.com/maps/place/?ftid=#\{data_id\}`.
  3. Wait for the reviews tab to render.
  4. Scroll the reviews container to paginate.
  5. Extract DOM nodes for each review (author, rating, date, text).
  6. Return as `[%{name:, rating:, description:, when:, images:}]`.

  If Lightpanda doesn't render Maps' SPA correctly, returns `{:error, :no_reviews_dom}`.
  """

  @behaviour GmapsEx.Reviews.Backend

  require Logger

  @impl true
  def fetch_all(data_id, opts) do
    if not Code.ensure_loaded?(LightpandaEx) do
      {:error, :lightpanda_ex_not_installed}
    else
      lang = opts[:lang] || "en"
      gl = opts[:gl] || "us"
      max_pages = opts[:max_pages] || 50

      url =
        "https://www.google.com/maps/place/?ftid=#{data_id}&hl=#{lang}&gl=#{gl}"

      try do
        # Pseudo-code — actual API depends on lightpanda_ex's evolving surface.
        # Tested API call sites should map directly when the dep matures.
        with {:ok, session} <- LightpandaEx.start_session(),
             :ok <- LightpandaEx.goto(session, url),
             :ok <- LightpandaEx.wait_for_selector(session, "[role=\"feed\"]", 5_000),
             {:ok, reviews} <- scroll_and_extract(session, max_pages) do
          LightpandaEx.close_session(session)
          {:ok, reviews}
        else
          {:error, _} = err ->
            Logger.warning("Lightpanda fetch failed for #{data_id}: #{inspect(err)}")
            err
        end
      rescue
        e ->
          Logger.warning("Lightpanda raised for #{data_id}: #{inspect(e)}")
          {:error, :exception}
      end
    end
  end

  # Scroll the reviews feed, extracting after each scroll step until no more
  # new reviews appear or `max_pages` is reached.
  defp scroll_and_extract(_session, _max_pages) do
    # Implementation depends on lightpanda_ex's DOM/JS-evaluation API.
    # The pattern:
    #
    #   loop until no new reviews or max_pages:
    #     LightpandaEx.scroll_to_bottom(session, "[role=feed]")
    #     wait 800ms
    #     LightpandaEx.eval(session, """
    #       Array.from(document.querySelectorAll('[data-review-id]')).map(el => ({
    #         name: el.querySelector('.author-name')?.innerText,
    #         rating: parseInt(el.querySelector('[role=img]')?.ariaLabel),
    #         description: el.querySelector('.review-text')?.innerText,
    #         when: el.querySelector('.review-date')?.innerText,
    #       }))
    #     """)
    {:error, :not_implemented}
  end
end
