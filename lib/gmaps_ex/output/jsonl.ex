defmodule GmapsEx.Output.Jsonl do
  @moduledoc "Append-only JSONL writer — one JSON object per line."

  alias GmapsEx.Place

  @spec append(Place.t(), Path.t()) :: :ok
  def append(%Place{} = place, path) do
    line = Jason.encode!(Place.to_attrs(place)) <> "\n"
    File.write!(path, line, [:append])
    :ok
  end

  @spec write([Place.t()], Path.t()) :: :ok
  def write(places, path) do
    body =
      places
      |> Enum.map(&Jason.encode!(Place.to_attrs(&1)))
      |> Enum.intersperse("\n")

    File.write!(path, [body, "\n"])
    :ok
  end
end
