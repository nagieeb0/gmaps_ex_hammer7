defmodule GmapsEx.Parser.Search do
  @moduledoc """
  Parses the JSON body returned by Google Maps' `tbm=map` search endpoint into
  a list of `%GmapsEx.Place{}` structs.

  Port of `ParseSearchResults` in `google-maps-scraper-main/gmaps/multiple.go:11-81`.

  ## Input contract

  Callers strip the leading `)]}'\\n` *and* the second newline-separated line
  (matching `removeFirstLine` in `searchjob.go:133`) before handing the JSON
  bytes here. We Jason-decode then walk the documented index paths.
  """

  alias GmapsEx.Parser.Path
  alias GmapsEx.Place

  @spec parse(binary()) :: {:ok, [Place.t()]} | {:error, term()}
  def parse(raw) when is_binary(raw) do
    with {:ok, data} <- Jason.decode(raw),
         {:ok, items} <- locate_items(data) do
      entries =
        items
        |> Enum.drop(1)
        |> Enum.flat_map(&parse_item/1)

      {:ok, entries}
    end
  end

  defp locate_items([container | _]) when is_list(container) do
    case Path.get(container, [1]) do
      list when is_list(list) and length(list) >= 2 -> {:ok, list}
      _ -> {:error, :empty_business_list}
    end
  end

  defp locate_items(_), do: {:error, :invalid_business_list_structure}

  defp parse_item(arr) when is_list(arr) do
    case Path.get(arr, [14]) do
      business when is_list(business) -> [build_place(business)]
      _ -> []
    end
  end

  defp parse_item(_), do: []

  # Index walks are taken verbatim from `multiple.go:43-75`.
  defp build_place(business) do
    %Place{
      input_id: Path.get(business, [0], :string),
      title: Path.get(business, [11], :string),
      categories: business |> Path.get([13], :list, []) |> Enum.map(&to_string/1),
      website: Path.get(business, [7, 0], :string),
      review_rating: Path.get(business, [4, 7], :float),
      review_count: Path.get(business, [4, 8], :int, 0),
      address: stringify_address(Path.get(business, [2], :list, [])),
      latitude: Path.get(business, [9, 2], :float),
      longitude: Path.get(business, [9, 3], :float),
      phone: business |> Path.get([178, 0, 0], :string, "") |> String.replace(" ", ""),
      open_hours: parse_hours(business),
      status: Path.get(business, [34, 4, 4], :string),
      timezone: Path.get(business, [30], :string),
      data_id: Path.get(business, [10], :string)
    }
  end

  defp stringify_address([]), do: nil

  defp stringify_address(parts) when is_list(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp parse_hours(business) do
    business
    |> Path.get([34, 1], :list, [])
    |> Enum.reduce(%{}, fn item, acc ->
      with [day | _] when is_binary(day) <- item,
           times when is_list(times) <- Path.get(item, [1]) do
        Map.put(acc, day, Enum.filter(times, &is_binary/1))
      else
        _ -> acc
      end
    end)
  end
end
