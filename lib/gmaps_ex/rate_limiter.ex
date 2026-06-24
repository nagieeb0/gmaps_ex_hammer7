defmodule GmapsEx.RateLimiter do
  @moduledoc """
  Module-based Hammer 7 limiter used by `GmapsEx.TenantLimiter` and
  `GmapsEx.Http.RateLimiter`. Single ETS backend per node.
  """

  use Hammer, backend: :ets
end
