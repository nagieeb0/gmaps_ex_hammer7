defmodule GmapsEx.Parser.Path do
  @moduledoc """
  Nested-array walker. Replaces `getNthElementAndCast[T]` from the Go scraper's
  `gmaps/entry.go`.

  Google's responses are deeply nested lists where data lives at fixed indices.
  This helper walks a path of integer indices, returning the leaf value or `nil`
  if any step fails — exactly like the Go generic helper that returns the zero
  value on type/bounds mismatch.
  """

  @doc """
  Walks `data` by the integer indices in `path`. Returns `nil` if any index is
  out of range or any intermediate value isn't a list.

      iex> GmapsEx.Parser.Path.get([[1, [2, 3]]], [0, 1, 1])
      3
      iex> GmapsEx.Parser.Path.get([[1, [2, 3]]], [0, 5])
      nil
  """
  @spec get(term(), [non_neg_integer()]) :: term()
  def get(data, []), do: data

  def get(data, [idx | rest]) when is_list(data) and is_integer(idx) and idx >= 0 do
    case Enum.at(data, idx) do
      nil -> nil
      next -> get(next, rest)
    end
  end

  def get(_data, _path), do: nil

  @doc """
  `get/2` with a typed cast. Returns the default when the value is missing or the
  wrong shape — never raises.
  """
  @spec get(term(), [non_neg_integer()], :string | :float | :int | :list | :map, term()) :: term()
  def get(data, path, type, default \\ nil) do
    case get(data, path) do
      nil -> default
      val -> cast(val, type, default)
    end
  end

  defp cast(v, :string, _d) when is_binary(v), do: v
  defp cast(v, :string, d) when is_nil(v), do: d
  defp cast(v, :string, _d), do: to_string(v)
  defp cast(v, :float, _d) when is_number(v), do: v / 1
  defp cast(_v, :float, d), do: d
  defp cast(v, :int, _d) when is_integer(v), do: v
  defp cast(v, :int, _d) when is_float(v), do: trunc(v)
  defp cast(_v, :int, d), do: d
  defp cast(v, :list, _d) when is_list(v), do: v
  defp cast(_v, :list, d), do: d
  defp cast(v, :map, _d) when is_map(v), do: v
  defp cast(_v, :map, d), do: d

  @doc """
  Try multiple paths in order, returning the first non-nil value. Used by the
  review parser where Google has shipped multiple structures and the Go code
  falls back through them (see `parseReviews` in `entry.go:455+`).
  """
  @spec first_of(term(), [[non_neg_integer()]]) :: term()
  def first_of(_data, []), do: nil

  def first_of(data, [path | rest]) do
    case get(data, path) do
      nil -> first_of(data, rest)
      "" -> first_of(data, rest)
      val -> val
    end
  end
end
