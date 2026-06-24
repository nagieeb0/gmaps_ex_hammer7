defmodule GmapsEx do
  @moduledoc """
  Public API surface.

  Two ways to invoke a scrape:

    * `search/2` — one-shot HTTP call to Google Maps' search XHR endpoint. Returns
      parsed `%GmapsEx.Place{}` structs. No DB, no Oban, no Broadway. Used to
      validate Phase 1 of the plan.

    * `place/2` — fetch one place's full detail by URL via HTML extraction. Used
      to validate Phase 2.

  Production use goes through the Oban + Broadway pipeline rather than these
  functions; see `mix gmaps.scrape`.
  """

  alias GmapsEx.Http.Client
  alias GmapsEx.Parser.{Place, Search}
  alias GmapsEx.PbBuilder

  @search_url "https://maps.google.com/search"

  @doc """
  Search Google Maps. Returns a list of `%GmapsEx.Place{}` structs (skeletal —
  only the fields the search endpoint exposes; call `place/2` per result for
  the rich detail).

  ## Example

      iex> GmapsEx.search("coffee shops", lat: 37.7749, lon: -122.4194, zoom: 13)
      {:ok, [%GmapsEx.Place{title: "Sightglass Coffee", ...}, ...]}
  """
  @spec search(String.t(), keyword()) :: {:ok, [GmapsEx.Place.t()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    params =
      PbBuilder.params(%{
        query: query,
        lat: Keyword.fetch!(opts, :lat),
        lon: Keyword.fetch!(opts, :lon),
        zoom: Keyword.fetch!(opts, :zoom),
        lang: Keyword.get(opts, :lang, "en")
      })

    with {:ok, body, _headers} <- Client.get(@search_url, params: params) do
      body
      |> strip_anti_hijack_prefix()
      |> Search.parse()
    end
  end

  @doc """
  Fetch and parse one place's full detail.

  The flow is two HTTP calls, no browser:

    1. GET `https://www.google.com/maps/place/?ftid={data_id}&hl=...&gl=...`
       — Google returns the generic Maps page but inlines a `<link rel="preload">`
       to `/maps/preview/place?pb=...` (a session-tokenized place-detail XHR URL).
    2. GET that preview URL → `)]}'`-prefixed JSON → `GmapsEx.Parser.Place`.

  ## Why two calls

  Step 1 hands us a fresh, session-scoped `pb=` payload that Google's servers
  will accept. Reverse-engineering a static `pb=` template would save a request
  but is fragile. Two HTTP calls per place is still ~10× faster than a browser.

  ## Options

    * `:data_id` — required if `url` is not already a `?ftid=` URL
    * `:lang` — defaults to `"en"`
    * `:gl` — country geolocation code, defaults to `"us"` — set this when scraping
      non-US queries (`"fr"`, `"jp"`, etc.) or Google will route to your IP's region
  """
  @spec place(String.t(), keyword()) :: {:ok, GmapsEx.Place.t()} | {:error, term()}
  def place(url_or_data_id, opts \\ []) do
    lang = Keyword.get(opts, :lang, "en")
    gl = Keyword.get(opts, :gl, "us")

    html_url =
      cond do
        String.starts_with?(url_or_data_id, "http") -> url_or_data_id
        true -> "https://www.google.com/maps/place/?ftid=#{url_or_data_id}"
      end

    with {:ok, html, _} <- Client.get(html_url, params: [{"hl", lang}, {"gl", gl}]),
         {:ok, preview_url} <- extract_preview_url(html),
         {:ok, body, _} <- Client.get(preview_url),
         {:ok, place} <- Place.parse(strip_anti_hijack_prefix(body)) do
      {:ok, place}
    end
  end

  defp extract_preview_url(html) do
    case Regex.run(~r{href="(/maps/preview/place\?[^"]+)"}, html) do
      [_, path] ->
        {:ok, "https://www.google.com" <> String.replace(path, "&amp;", "&")}

      _ ->
        {:error, :preview_url_not_found}
    end
  end

  defp strip_anti_hijack_prefix(body) do
    body
    |> String.trim_leading(")]}'")
    |> String.trim_leading()
    |> drop_first_line()
  end

  defp drop_first_line(body) do
    case String.split(body, "\n", parts: 2) do
      [_first, rest] -> rest
      [single] -> single
    end
  end
end
