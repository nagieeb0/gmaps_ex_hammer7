defmodule GmapsEx.Parser.Hours do
  @moduledoc """
  Parses opening-hours arrays out of a place-detail darray.

  Port of `getHours` in `gmaps/entry.go:571+`. Google ships two structures
  in the wild — a newer one at `darray[203][0]` and an older one at
  `darray[34][1]`. We try the new one first and fall back.
  """

  alias GmapsEx.Parser.Path

  @spec parse(list()) :: %{optional(String.t()) => [String.t()]}
  def parse(darray) when is_list(darray) do
    items =
      case Path.get(darray, [203, 0]) do
        list when is_list(list) and list != [] -> list
        _ -> Path.get(darray, [34, 1], :list, [])
      end

    Enum.reduce(items, %{}, fn item, acc ->
      case parse_item(item) do
        {day, [_ | _] = times} -> Map.put(acc, day, times)
        _ -> acc
      end
    end)
  end

  def parse(_), do: %{}

  defp parse_item(item) when is_list(item) do
    day = Path.get(item, [0], :string, "")

    times =
      case Path.get(item, [3]) do
        list when is_list(list) and list != [] -> extract_new_format(list)
        _ -> extract_old_format(item)
      end

    {day, times}
  end

  defp parse_item(_), do: {"", []}

  defp extract_new_format(slots) do
    Enum.flat_map(slots, fn slot ->
      case Path.get(slot, [0]) do
        s when is_binary(s) and s != "" -> [s]
        _ -> []
      end
    end)
  end

  defp extract_old_format(item) do
    item
    |> Path.get([1], :list, [])
    |> Enum.filter(&is_binary/1)
  end
end
