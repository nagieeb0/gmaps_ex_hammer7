defmodule GmapsEx.Reviews.Backend do
  @moduledoc """
  Behaviour for review-fetching backends.

  GmapsEx ships with one default backend: `GmapsEx.Reviews.Backend.Http` — pure
  HTTP, gets the ~10 inline reviews from the place-detail XHR (limited because
  Google's `/maps/rpc/listugcposts` requires browser-session auth, see
  `lib/gmaps_ex/reviews.ex`).

  **For full reviews extraction (1000+ per place, matching the Go scraper's
  output)**, plug in a browser-based backend. The Go scraper does this via
  Playwright Firefox stealth running the RPC from inside a browser context;
  any equivalent in Elixir works.

  ## Implementing your own backend

  Add a dep like `{:playwright, "~> 1.x"}` (or `playwright_ex`, see hex.pm) and
  write a module:

      defmodule MyApp.PlaywrightReviewsBackend do
        @behaviour GmapsEx.Reviews.Backend

        @impl true
        def fetch_all(data_id, opts) do
          # 1. Start a Playwright browser context (cached or fresh).
          # 2. Navigate to https://www.google.com/maps/place/?ftid=#\{data_id\}&hl=#\{lang\}&gl=#\{gl\}
          # 3. Click the "Reviews" tab.
          # 4. Scroll the reviews panel to trigger pagination.
          # 5. Extract each review's DOM (author, rating, text, when, photos).
          # 6. Return {:ok, [%\{name: ..., rating: ..., description: ..., when: ..., images: ...\}]}.
          #
          # Or use the Playwright cookie jar to authenticate the RPC call and
          # parse responses with GmapsEx.Reviews.RpcParser — same code, just
          # behind a real browser session.
        end
      end

  Then wire it in `config/runtime.exs`:

      config :gmaps_ex, GmapsEx.Workers.ReviewsWorker,
        backend: MyApp.PlaywrightReviewsBackend

  All `GmapsEx.Workers.ReviewsWorker` invocations now use your backend.

  ## Why not just include Playwright?

  Playwright pulls Node.js, npm, and ~200MB of Chromium. For a library you
  embed in your Phoenix app, that's a heavy default. We provide the pluggable
  contract so the dep is opt-in.
  """

  @type review :: %{
          required(:name) => String.t(),
          required(:rating) => integer(),
          optional(:description) => String.t() | nil,
          optional(:when) => String.t() | nil,
          optional(:profile_picture) => String.t() | nil,
          optional(:images) => [String.t()]
        }

  @doc """
  Fetch every review for the given `data_id`. Options:

    * `:lang` — language code (default `"en"`)
    * `:gl` — country code (default `"us"`)
    * `:max_pages` — pagination cap (default `100`, ~2000 reviews max)
  """
  @callback fetch_all(data_id :: String.t(), opts :: keyword()) ::
              {:ok, [review()]} | {:error, term()}
end
