defmodule GmapsEx.DataCase do
  @moduledoc """
  Test case for tests that touch the database. Wraps each test in a
  transaction via Ecto's SQL sandbox.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import GmapsEx.DataCase

      alias GmapsEx.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GmapsEx.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
