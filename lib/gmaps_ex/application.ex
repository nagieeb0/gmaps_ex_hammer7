defmodule GmapsEx.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        GmapsEx.Repo,
        {Oban, Application.fetch_env!(:gmaps_ex, Oban)},
        {Phoenix.PubSub, name: GmapsEx.PubSub},
        GmapsEx.RateLimiter,
        GmapsEx.Http.ProxyPool,
        GmapsEx.Http.SessionStore,
        GmapsEx.Dedupe,
        GmapsEx.Exiter
      ]
      |> maybe_skip_repo()

    opts = [strategy: :one_for_one, name: GmapsEx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_skip_repo(children) do
    if System.get_env("GMAPS_NO_DB") == "1" do
      Enum.reject(children, &(&1 == GmapsEx.Repo or match?({Oban, _}, &1)))
    else
      children
    end
  end
end
