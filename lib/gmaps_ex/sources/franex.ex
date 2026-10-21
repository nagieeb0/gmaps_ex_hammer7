defmodule GmapsEx.Sources.Franex do
  @moduledoc """
  Scraper for the Franex exhibitor directory (Egyptian–Saudi International Franchise Expo).

  Every exhibitor is a brand that is openly selling franchises, and each detail page
  carries a franchise spec sheet — including `Space Required`, which is the one field
  that matches a physical unit directly.

  Server-rendered WordPress, 12 cards per listing page, ~9 pages. Not Google: be polite.
  """

  require Logger

  @base "https://egyptfranchiseexpo.com"
  @list_path "/our-exhibitors"
  @delay_ms 1200
  @max_pages 12

  # Stand-in ceiling for "150 m and up" — large enough to fit any real unit.
  @open_upper 3000

  @type exhibitor :: %{name: String.t(), slug: String.t(), url: String.t()}
  @type spec_sheet :: %{optional(atom()) => term()}

  # Label in the spec table -> our field name. Anything unmapped survives in :raw.
  @labels %{
    "country" => :country,
    "business category" => :category,
    "establishment year" => :established,
    "number of branches" => :branches,
    "franchise fees" => :franchise_fee,
    "royalty fees" => :royalty,
    "marketing fees" => :marketing_fee,
    "center office" => :head_office,
    "number of labor" => :staff,
    "training period" => :training,
    "equipment cost" => :equipment_cost,
    "space required" => :space_required,
    "fit out cost" => :fit_out_cost,
    "contract duration" => :contract_years,
    "payback period" => :payback,
    "avg. investment" => :avg_investment,
    "avg investment" => :avg_investment
  }

  @doc "Fetch every exhibitor across all listing pages. Returns unique `%{name, slug, url}`."
  @spec fetch_exhibitors(keyword()) :: {:ok, [exhibitor()]} | {:error, term()}
  def fetch_exhibitors(opts \\ []) do
    max_pages = Keyword.get(opts, :pages, @max_pages)

    # A transient 429 from this WordPress host must not truncate the directory:
    # retry the page, and only stop on two *successful* empty pages in a row.
    1..max_pages
    |> Enum.reduce_while({[], 0}, fn page, {acc, empties} ->
      case fetch_list_page_retrying(page) do
        {:ok, []} when empties >= 1 ->
          {:halt, {acc, empties}}

        {:ok, []} ->
          pause()
          {:cont, {acc, empties + 1}}

        {:ok, items} ->
          pause()
          {:cont, {acc ++ items, 0}}

        {:error, reason} ->
          Logger.warning("franex: page #{page} failed after retries: #{inspect(reason)}")
          pause()
          {:cont, {acc, empties}}
      end
    end)
    |> elem(0)
    |> Enum.uniq_by(& &1.slug)
    |> then(&{:ok, &1})
  end

  defp fetch_list_page_retrying(page, attempt \\ 1) do
    case fetch_list_page(page) do
      {:ok, items} when items != [] ->
        {:ok, items}

      other when attempt >= 4 ->
        other

      _ ->
        Process.sleep(attempt * 1500)
        fetch_list_page_retrying(page, attempt + 1)
    end
  end

  defp fetch_list_page(1), do: do_list(@base <> @list_path <> "/")
  defp fetch_list_page(n), do: do_list(@base <> @list_path <> "/page/#{n}/")

  defp do_list(url) do
    with {:ok, body, _} <- GmapsEx.Http.Client.get(url) do
      links =
        ~r/#{Regex.escape(@base)}\/project\/([a-z0-9\-]+)\//
        |> Regex.scan(body)
        |> Enum.map(fn [full, slug] -> %{slug: slug, url: full, name: slug_to_name(slug)} end)
        |> Enum.uniq_by(& &1.slug)

      {:ok, links}
    end
  end

  @doc "Fetch and parse one exhibitor's franchise spec sheet."
  @spec fetch_detail(exhibitor(), pos_integer()) :: {:ok, spec_sheet()} | {:error, term()}
  def fetch_detail(ex, attempt \\ 1)

  def fetch_detail(%{url: url} = ex, attempt) do
    with {:error, reason} <- do_detail(ex, url) do
      if attempt >= 4 do
        Logger.warning("franex: #{ex.slug} failed after retries: #{inspect(reason)}")
        {:error, reason}
      else
        Process.sleep(attempt * 1500)
        fetch_detail(ex, attempt + 1)
      end
    end
  end

  defp do_detail(ex, url) do
    with {:ok, body, _} <- GmapsEx.Http.Client.get(url) do
      raw = parse_spec_table(body)

      sheet =
        raw
        |> Enum.reduce(%{}, fn {label, value}, acc ->
          case Map.fetch(@labels, String.downcase(String.trim(label))) do
            {:ok, field} -> Map.put(acc, field, value)
            :error -> acc
          end
        end)
        |> Map.put(:raw, raw)
        |> Map.put(:name, heading(body) || ex.name)
        |> Map.put(:slug, ex.slug)
        |> Map.put(:url, url)
        |> normalize()

      {:ok, sheet}
    end
  end

  # Two <td> per row: label then value.
  defp parse_spec_table(body) do
    ~r/<td[^>]*>\s*(.{1,80}?)\s*<\/td>\s*<td[^>]*>\s*(.{0,200}?)\s*<\/td>/s
    |> Regex.scan(body)
    |> Enum.map(fn [_, label, value] -> {strip_tags(label), strip_tags(value)} end)
    |> Enum.reject(fn {l, v} -> l == "" or v == "" end)
  end

  defp heading(body) do
    case Regex.run(~r/<h1[^>]*>\s*(.{1,120}?)\s*<\/h1>/s, body) do
      [_, h] -> h |> strip_tags() |> nil_if_blank()
      _ -> nil
    end
  end

  defp normalize(sheet) do
    sheet
    |> Map.put(:branches_n, to_int(sheet[:branches]))
    |> Map.put(:established_n, to_int(sheet[:established]))
    |> Map.put(:space_m2, parse_space(sheet[:space_required]))
  end

  @doc """
  Parse a free-text `Space Required` value into `{min_m2, max_m2}`.

  The field is hand-typed per exhibitor, so the shapes vary wildly:
  `"From 150-250 square meters"`, `"50 sqm to 700 sqm"`, `"12m DT - 200 m BR"`,
  `"Min Size : 133m2, Recommended Size : 185 - 250 m2"`, `"160up"`,
  `"Starting from 25 meters"`. Rather than enumerate separators, take every
  plausible area figure in the string and span them — then widen the upper bound
  when the text says "from"/"up"/"+"/"فأكثر" and gave only one number.
  """
  @spec parse_space(String.t() | nil) :: {integer(), integer()} | nil
  def parse_space(nil), do: nil

  def parse_space(text) do
    nums =
      ~r/\d[\d,]*/u
      |> Regex.scan(text)
      |> Enum.map(fn [n] -> n |> String.replace(",", "") |> String.to_integer() end)
      |> Enum.filter(&(&1 >= 10 and &1 <= 3000))

    case nums do
      [] -> nil
      [n] -> if open_ended?(text), do: {n, @open_upper}, else: {n, n}
      many -> {Enum.min(many), Enum.max(many)}
    end
  end

  # "starting from 25 meters", "160up", "200+", "150 م فأكثر" — no ceiling stated.
  defp open_ended?(text) do
    t = String.downcase(text)

    String.contains?(t, ["up", "+", "and above", "or more", "minimum", "min ", "min:", "starting"]) or
      String.contains?(text, ["فأكثر", "فاكثر", "وأكثر", "واكثر", "بحد أدنى"])
  end

  @doc "Does this brand's required floor area overlap the unit on offer?"
  @spec space_fits?(spec_sheet(), integer(), integer()) :: boolean()
  def space_fits?(%{space_m2: {lo, hi}}, unit_lo, unit_hi)
      when is_integer(lo) and is_integer(hi),
      do: lo <= unit_hi and hi >= unit_lo

  def space_fits?(_, _, _), do: false

  defp strip_tags(s) do
    s
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/&nbsp;|&#160;/, " ")
    |> String.replace(~r/&#8211;|&#8212;|&ndash;|&mdash;/, "-")
    |> String.replace("&amp;", "&")
    |> String.replace(~r/&#(\d+);/u, fn e ->
      case Regex.run(~r/\d+/, e) do
        [n] -> <<String.to_integer(n)::utf8>>
        _ -> e
      end
    end)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp to_int(nil), do: nil

  defp to_int(s) when is_binary(s) do
    case Regex.run(~r/\d[\d,]*/, s) do
      [m] -> m |> String.replace(",", "") |> String.to_integer()
      _ -> nil
    end
  end

  defp to_int(n) when is_integer(n), do: n

  defp slug_to_name(slug) do
    slug
    |> String.replace("-", " ")
    |> String.replace(~r/\s+\d+$/, "")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(s), do: s

  defp pause, do: Process.sleep(@delay_ms)
end
