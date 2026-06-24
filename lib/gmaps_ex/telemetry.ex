defmodule GmapsEx.Telemetry do
  @moduledoc """
  Telemetry event list + a small console attacher that logs progress to stdout.
  Production deployments should attach PromEx / their preferred exporter.
  """

  require Logger

  @events [
    [:gmaps_ex, :search, :ok],
    [:gmaps_ex, :search, :error],
    [:gmaps_ex, :place, :ok],
    [:gmaps_ex, :place, :error],
    [:gmaps_ex, :http, :request],
    [:gmaps_ex, :run, :complete]
  ]

  def events, do: @events

  @doc "Attach a console handler that logs every event at info level."
  def attach_console do
    :telemetry.attach_many(
      "gmaps-console",
      @events,
      &handle/4,
      nil
    )
  end

  defp handle([:gmaps_ex, :search, :ok], %{count: n}, %{query: q}, _) do
    Logger.info("search ok: #{q} → #{n} places")
  end

  defp handle([:gmaps_ex, :search, :error], _, %{query: q, reason: r}, _) do
    Logger.warning("search error: #{q} → #{r}")
  end

  defp handle([:gmaps_ex, :place, :ok], _, %{title: t}, _) do
    Logger.info("place ok: #{t}")
  end

  defp handle([:gmaps_ex, :place, :error], _, %{url: u, reason: r}, _) do
    Logger.warning("place error: #{u} → #{r}")
  end

  defp handle([:gmaps_ex, :run, :complete], %{places: p, seeds: s}, _, _) do
    Logger.info("run complete: #{s} seeds, #{p} places")
  end

  defp handle(_, _, _, _), do: :ok
end
