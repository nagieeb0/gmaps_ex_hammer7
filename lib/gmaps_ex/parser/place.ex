defmodule GmapsEx.Parser.Place do
  @moduledoc """
  Parses the place-detail JSON into a `%GmapsEx.Place{}`.

  Port of `EntryFromJSON` in `gmaps/entry.go:279-453`. Mechanical translation of
  every `getNthElementAndCast[T](darray, X, Y, Z)` call into a `Parser.Path.get/2-4`
  call against the decoded JSON.

  Note that the CID is read from the *outer* array `jd`, not the `darray` at `jd[6]`
  — that asymmetry is preserved on purpose; it matches `entry.go:339`.
  """

  alias GmapsEx.Parser.{Hours, Path, Reviews}
  alias GmapsEx.Place

  @spec parse(binary()) :: {:ok, Place.t()} | {:error, term()}
  def parse(raw) when is_binary(raw) do
    with {:ok, jd} <- Jason.decode(raw),
         darray when is_list(darray) <- get_darray(jd) do
      {:ok, build(jd, darray)}
    else
      {:error, _} = err -> err
      _ -> {:error, :invalid_json}
    end
  end

  defp get_darray(jd) when is_list(jd) and length(jd) >= 7, do: Enum.at(jd, 6)
  defp get_darray(_), do: nil

  defp build(jd, darray) do
    inline_reviews = extract_inline_reviews(darray)

    %Place{
      link: Path.get(darray, [27], :string),
      title: Path.get(darray, [11], :string),
      categories: categories(darray),
      category: first_category(darray),
      address: address(darray),
      open_hours: Hours.parse(darray),
      popular_times: popular_times(darray),
      website: actual_url(Path.get(darray, [7, 0], :string)),
      phone: Path.get(darray, [178, 0, 0], :string),
      plus_code: Path.get(darray, [183, 2, 2, 0], :string),
      review_count: review_count(darray),
      review_rating: Path.get(darray, [4, 7], :float),
      latitude: Path.get(darray, [9, 2], :float),
      longitude: Path.get(darray, [9, 3], :float),
      cid: Path.get(jd, [25, 3, 0, 13, 0, 0, 1], :string),
      status: Path.get(darray, [34, 4, 4], :string),
      description: Path.get(darray, [32, 1, 1], :string),
      reviews_link: Path.get(darray, [4, 3, 0], :string),
      thumbnail: Path.get(darray, [72, 0, 1, 6, 0], :string),
      timezone: Path.get(darray, [30], :string),
      price_range: Path.get(darray, [4, 2], :string),
      data_id: Path.get(darray, [10], :string),
      place_id: Path.get(darray, [78], :string),
      images: images(darray),
      reservations: reservations(darray),
      order_online: order_online(darray),
      menu: menu(darray),
      owner: owner(darray),
      complete_address: complete_address(darray),
      about: about(darray),
      reviews_per_rating: reviews_per_rating(darray),
      extra: %{"inline_reviews" => inline_reviews}
    }
  end

  defp extract_inline_reviews(darray) do
    case Path.get(darray, [175, 9, 0, 0]) do
      list when is_list(list) and list != [] -> Reviews.parse_inline(list)
      _ -> darray |> Path.get([175, 9, 0], :list, []) |> Reviews.parse_inline()
    end
  end

  # The rating histogram is the authoritative total: summed, it matches what
  # Maps prints and what the browser-based scrapers report. `darray[37, 1]`
  # counts something else — measured against 130 places scraped both ways, it
  # came in at a median 0.45x the real figure, and read 1 for a place with 33
  # ratings. Use it only when the histogram is absent.
  defp review_count(darray) do
    case histogram_total(darray) do
      n when n > 0 ->
        n

      _ ->
        case Path.get(darray, [37, 1]) do
          n when is_integer(n) and n > 0 -> n
          n when is_float(n) and n > 0 -> trunc(n)
          _ -> Path.get(darray, [4, 8], :int, 0)
        end
    end
  end

  defp histogram_total(darray) do
    Enum.reduce(0..4, 0, fn i, acc -> acc + Path.get(darray, [175, 3, i], :int, 0) end)
  end

  defp categories(darray) do
    darray
    |> Path.get([13], :list, [])
    |> Enum.map(&to_string/1)
  end

  defp first_category(darray) do
    case Path.get(darray, [13]) do
      [first | _] when is_binary(first) -> first
      _ -> nil
    end
  end

  defp address(darray) do
    raw = Path.get(darray, [18], :string, "")
    title = Path.get(darray, [11], :string, "")

    raw
    |> String.trim_leading(title <> ",")
    |> String.trim()
  end

  defp popular_times(_darray) do
    # The Go code (`gmaps/entry.go` getPopularTimes — not shown in this slice) walks
    # a complex structure. Left as :extra map for v1; can be filled in once we have
    # a known place fixture with popular times to test against.
    %{}
  end

  defp actual_url(nil), do: nil

  defp actual_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: q} when is_binary(q) ->
        q
        |> URI.decode_query()
        |> Map.get("q", url)

      _ ->
        url
    end
  end

  # Categorised gallery (`[171, 0]`) when Google ships it; otherwise the place-photo
  # strip at `[51, 0]` (each entry: image url at `[6, 0]`), which carries no category.
  defp images(darray) do
    case categorised_images(darray) do
      [] -> strip_images(darray)
      imgs -> imgs
    end
  end

  defp categorised_images(darray) do
    darray
    |> Path.get([171, 0], :list, [])
    |> Enum.flat_map(fn item ->
      link = Path.get(item, [3, 0, 6, 0], :string)
      source = Path.get(item, [2], :string)

      if is_binary(link) and link != "" and is_binary(source) and source != "" do
        [%{title: source, image: link}]
      else
        []
      end
    end)
  end

  defp strip_images(darray) do
    darray
    |> Path.get([51, 0], :list, [])
    |> Enum.flat_map(fn item ->
      case Path.get(item, [6, 0], :string) do
        "http" <> _ = link -> [%{title: "photo", image: link}]
        _ -> []
      end
    end)
    |> Enum.uniq_by(& &1.image)
  end

  defp reservations(darray) do
    link_sources(darray, [46], [0], [1])
  end

  defp order_online(darray) do
    primary = Path.get(darray, [75, 0, 1, 2], :list, [])
    arr = if primary == [], do: Path.get(darray, [75, 0, 0, 2], :list, []), else: primary

    Enum.flat_map(arr, fn item ->
      link = Path.get(item, [1, 2, 0], :string)
      source = Path.get(item, [0, 0], :string)

      if is_binary(link) and link != "" and is_binary(source) and source != "" do
        [%{link: link, source: source}]
      else
        []
      end
    end)
  end

  defp link_sources(darray, base_path, link_path, source_path) do
    darray
    |> Path.get(base_path, :list, [])
    |> Enum.flat_map(fn item ->
      link = Path.get(item, link_path, :string)
      source = Path.get(item, source_path, :string)

      if is_binary(link) and link != "" and is_binary(source) and source != "" do
        [%{link: link, source: source}]
      else
        []
      end
    end)
  end

  defp menu(darray) do
    %{
      link: Path.get(darray, [38, 0], :string),
      source: Path.get(darray, [38, 1], :string)
    }
  end

  defp owner(darray) do
    id = Path.get(darray, [57, 2], :string)
    name = Path.get(darray, [57, 1], :string)

    link =
      if is_binary(id) and id != "" do
        "https://www.google.com/maps/contrib/#{id}"
      end

    %{id: id, name: name, link: link}
  end

  defp complete_address(darray) do
    %{
      borough: Path.get(darray, [183, 1, 0], :string),
      street: Path.get(darray, [183, 1, 1], :string),
      city: Path.get(darray, [183, 1, 3], :string),
      postal_code: Path.get(darray, [183, 1, 4], :string),
      state: Path.get(darray, [183, 1, 5], :string),
      country: Path.get(darray, [183, 1, 6], :string)
    }
  end

  defp about(darray) do
    darray
    |> Path.get([100, 1], :list, [])
    |> Enum.flat_map(fn el ->
      id = Path.get(el, [0], :string)
      name = Path.get(el, [1], :string)

      options =
        el
        |> Path.get([2], :list, [])
        |> Enum.flat_map(fn opt ->
          opt_name = Path.get(opt, [1], :string)
          enabled = Path.get(opt, [2, 1, 0, 0], :int, 0) == 1

          if is_binary(opt_name) and opt_name != "" do
            [%{name: opt_name, enabled: enabled}]
          else
            []
          end
        end)

      [%{id: id, name: name, options: options}]
    end)
  end

  defp reviews_per_rating(darray) do
    %{
      "1" => Path.get(darray, [175, 3, 0], :int, 0),
      "2" => Path.get(darray, [175, 3, 1], :int, 0),
      "3" => Path.get(darray, [175, 3, 2], :int, 0),
      "4" => Path.get(darray, [175, 3, 3], :int, 0),
      "5" => Path.get(darray, [175, 3, 4], :int, 0)
    }
  end

  # User-review extraction is delegated; this function is exposed in case
  # callers want a separate review pass.
  @spec parse_inline_reviews(list()) :: [map()]
  def parse_inline_reviews(darray) do
    case Path.get(darray, [175, 9, 0, 0]) do
      list when is_list(list) and list != [] -> Reviews.parse_inline(list)
      _ -> darray |> Path.get([175, 9, 0], :list, []) |> Reviews.parse_inline()
    end
  end
end
