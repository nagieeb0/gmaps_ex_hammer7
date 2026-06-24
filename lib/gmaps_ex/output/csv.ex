defmodule GmapsEx.Output.Csv do
  @moduledoc """
  Streaming CSV writer. Columns mirror `Entry.CsvHeaders` in
  `gmaps/entry.go:159+` so output is directly comparable to the Go scraper.
  """

  NimbleCSV.define(GmapsEx.Output.CsvParser, separator: ",", escape: "\"")

  alias GmapsEx.Place

  @headers ~w(
    input_id link title category address open_hours popular_times
    website phone plus_code review_count review_rating reviews_per_rating
    latitude longitude cid status description reviews_link thumbnail
    timezone price_range data_id place_id images reservations order_online
    menu owner complete_address about emails
  )

  @doc "Write places to a CSV file at `path`. Returns `:ok` on success."
  @spec write([Place.t()], Path.t()) :: :ok
  def write(places, path) do
    rows = Enum.map(places, &row/1)

    [@headers | rows]
    |> GmapsEx.Output.CsvParser.dump_to_iodata()
    |> then(&File.write!(path, &1))

    :ok
  end

  defp row(%Place{} = p) do
    [
      p.input_id || "",
      p.link || "",
      p.title || "",
      p.category || "",
      p.address || "",
      json(p.open_hours),
      json(p.popular_times),
      p.website || "",
      p.phone || "",
      p.plus_code || "",
      to_string(p.review_count || 0),
      to_string(p.review_rating || ""),
      json(p.reviews_per_rating),
      to_string(p.latitude || ""),
      to_string(p.longitude || ""),
      p.cid || "",
      p.status || "",
      p.description || "",
      p.reviews_link || "",
      p.thumbnail || "",
      p.timezone || "",
      p.price_range || "",
      p.data_id || "",
      p.place_id || "",
      json(p.images),
      json(p.reservations),
      json(p.order_online),
      json(p.menu),
      json(p.owner),
      json(p.complete_address),
      json(p.about),
      Enum.join(p.emails || [], ";")
    ]
  end

  defp json(nil), do: ""
  defp json(v), do: Jason.encode!(v)
end
