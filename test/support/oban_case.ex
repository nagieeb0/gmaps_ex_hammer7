defmodule GmapsEx.ObanCase do
  @moduledoc """
  Test case for Oban-worker tests. Builds on `DataCase` and pulls in Oban's
  testing helpers (configured `:manual` mode in `config/test.exs`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use GmapsEx.DataCase
      use Oban.Testing, repo: GmapsEx.Repo
    end
  end
end
