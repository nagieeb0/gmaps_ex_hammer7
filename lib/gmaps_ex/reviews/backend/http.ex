defmodule GmapsEx.Reviews.Backend.Http do
  @moduledoc """
  Default pure-HTTP backend. Delegates to `GmapsEx.Reviews.fetch_all/2`.

  This is limited — Google's RPC endpoint requires browser-session cookies
  we can't fully obtain without a real browser. Returns `{:ok, []}` in the
  common case where Google rejects the unauthenticated call. The ~10 inline
  reviews are extracted separately by `GmapsEx.Parser.Place` from the
  place-detail response and persisted by `GmapsEx.Workers.PlaceWorker`.

  See `GmapsEx.Reviews.Backend` for how to plug in a browser-based backend
  that gets full pagination.
  """

  @behaviour GmapsEx.Reviews.Backend

  @impl true
  def fetch_all(data_id, opts) do
    GmapsEx.Reviews.fetch_all(data_id, opts)
  end
end
