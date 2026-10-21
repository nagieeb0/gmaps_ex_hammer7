defmodule Mix.Tasks.Gmaps.Malqa.Franex do
  @moduledoc """
  Track B, zero Google requests: pull the Franex franchise directory and rank the
  brands whose required floor area actually fits the Al Malqa unit.

      mix gmaps.malqa.franex
      mix gmaps.malqa.franex --unit-min 180 --unit-max 200 --all-categories
      mix gmaps.malqa.franex --dry-run

  Each exhibitor is a brand openly selling franchises, and every detail page carries
  a spec sheet: country, branches, franchise fee, average investment, and
  `Space Required` — the field that matches a physical unit directly.
  """

  use Mix.Task

  alias GmapsEx.Sources.Franex

  @shortdoc "Rank Franex franchise brands against the Al Malqa unit"

  @out_dir "malqa"

  @switches [
    unit_min: :integer,
    unit_max: :integer,
    all_categories: :boolean,
    country: :string,
    pages: :integer,
    concurrency: :integer,
    dry_run: :boolean,
    out_dir: :string
  ]

  # Business Category values that mean food & beverage.
  @fnb ~w(restaurant cafe café coffee food bakery beverage juice sweet dessert
          patisserie pizza burger grill catering tea مطعم مطاعم كافيه قهوة مخبز حلويات)

  @headers ~w(rank score fit brand country category branches established
              space_min_m2 space_max_m2 franchise_fee avg_investment fit_out_cost
              equipment_cost royalty marketing_fee contract_years payback
              head_office staff training url why_ar status_owner notes_owner)

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    # 200 m² ground floor, 350 m² with the mezzanine built out.
    unit_min = opts[:unit_min] || 200
    unit_max = opts[:unit_max] || 350
    out_dir = opts[:out_dir] || @out_dir

    Mix.Task.run("app.start")

    Mix.shell().info(":: Franex directory — unit #{unit_min}-#{unit_max} m²")

    {:ok, exhibitors} = Franex.fetch_exhibitors(pages: opts[:pages] || 12)
    Mix.shell().info(":: #{length(exhibitors)} exhibitors listed")

    if opts[:dry_run] do
      exhibitors |> Enum.take(5) |> Enum.each(&Mix.shell().info("   #{&1.name}  #{&1.url}"))
      Mix.shell().info(":: dry-run — no detail pages fetched")
      System.halt(0)
    end

    sheets = fetch_details(exhibitors, opts[:concurrency] || 1)
    Mix.shell().info(":: #{length(sheets)} spec sheets parsed")

    rows =
      sheets
      |> filter_category(opts[:all_categories])
      |> filter_country(opts[:country])
      |> Enum.map(&score(&1, unit_min, unit_max))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> Map.put(r, :rank, i) end)

    File.mkdir_p!(out_dir)
    write_json(sheets, Path.join(out_dir, "franex.json"), unit_min, unit_max)
    write_csv(rows, Path.join(out_dir, "track-b-franex.csv"))

    fits = Enum.count(rows, &(&1.fit == "yes"))

    Mix.shell().info("""

    :: #{length(rows)} F&B franchise brands ranked
    :: #{fits} of them fit #{unit_min}-#{unit_max} m² outright
    :: #{Path.join(out_dir, "track-b-franex.csv")}
    """)

    rows |> Enum.take(12) |> Enum.each(&preview/1)
  end

  defp fetch_details(exhibitors, concurrency) do
    exhibitors
    |> Task.async_stream(
      fn ex ->
        # Small WordPress host, not Google: one at a time, spaced out.
        Process.sleep(1200)

        case Franex.fetch_detail(ex) do
          {:ok, sheet} -> sheet
          _ -> nil
        end
      end,
      max_concurrency: concurrency,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, sheet} -> [sheet]
      _ -> []
    end)
  end

  defp filter_category(sheets, true), do: sheets

  defp filter_category(sheets, _) do
    Enum.filter(sheets, fn s ->
      hay = String.downcase("#{s[:category]} #{s[:name]}")
      Enum.any?(@fnb, &String.contains?(hay, &1))
    end)
  end

  defp filter_country(sheets, nil), do: sheets

  defp filter_country(sheets, country) do
    want = String.downcase(country)
    Enum.filter(sheets, &String.contains?(String.downcase("#{&1[:country]}"), want))
  end

  # Space fit dominates: a brand that needs 400 m² cannot use this unit at any price.
  defp score(sheet, unit_min, unit_max) do
    fits = Franex.space_fits?(sheet, unit_min, unit_max)
    space = sheet[:space_m2]

    space_pts =
      cond do
        fits -> 45
        is_nil(space) -> 12
        elem(space, 0) > unit_max -> max(0, 20 - div(elem(space, 0) - unit_max, 20))
        true -> 15
      end

    branches = sheet[:branches_n] || 0

    # Same sweet spot as Track A: proven format, still hungry, founder still answers.
    branch_pts =
      cond do
        branches >= 5 and branches <= 40 -> 25
        branches >= 3 -> 18
        branches > 40 -> 12
        branches >= 1 -> 8
        true -> 3
      end

    maturity_pts =
      case sheet[:established_n] do
        nil -> 5
        y when y <= 2015 -> 15
        y when y <= 2021 -> 12
        _ -> 7
      end

    detail_pts =
      Enum.count(
        [:franchise_fee, :avg_investment, :fit_out_cost, :head_office],
        &(sheet[&1] not in [nil, ""])
      ) * 3

    %{
      score: space_pts + branch_pts + maturity_pts + detail_pts,
      fit: if(fits, do: "yes", else: "no"),
      sheet: sheet,
      why_ar: why_ar(sheet, fits, unit_min, unit_max)
    }
  end

  defp why_ar(sheet, fits, unit_min, unit_max) do
    parts = []

    parts =
      case sheet[:space_m2] do
        {a, b} when fits -> ["المساحة المطلوبة #{a}-#{b} م² — تنطبق على الصالة #{unit_min}-#{unit_max} م²" | parts]
        {a, b} -> ["المساحة المطلوبة #{a}-#{b} م²" | parts]
        _ -> parts
      end

    parts = if sheet[:branches_n], do: ["#{sheet[:branches_n]} فرع" | parts], else: parts
    parts = if sheet[:country], do: ["#{sheet[:country]}" | parts], else: parts

    parts =
      if sheet[:avg_investment],
        do: ["استثمار تقديري #{sheet[:avg_investment]}" | parts],
        else: parts

    parts |> Enum.reverse() |> Enum.join(" · ")
  end

  defp preview(r) do
    s = r.sheet
    flag = if r.fit == "yes", do: "✓", else: " "
    Mix.shell().info("   #{flag} #{String.pad_leading("#{r.score}", 3)}  #{s[:name]}  (#{s[:country]}, #{s[:category]}, #{s[:space_required]})")
  end

  defp write_json(sheets, path, unit_min, unit_max) do
    safe =
      Enum.map(sheets, fn sheet ->
        sheet
        |> Map.put(:space_fit, Franex.space_fits?(sheet, unit_min, unit_max))
        |> json_safe()
      end)

    File.write!(path, Jason.encode_to_iodata!(safe, pretty: true))
  end

  # :raw is a list of {label, value} tuples and :space_m2 is a {min, max} tuple;
  # neither is JSON-encodable as-is.
  defp json_safe(sheet) do
    sheet
    |> Map.update(:raw, %{}, &Map.new/1)
    |> Map.update(:space_m2, nil, fn
      {a, b} -> %{"min" => a, "max" => b}
      other -> other
    end)
  end

  defp write_csv(rows, path) do
    body =
      rows
      |> Enum.map(fn r ->
        s = r.sheet
        {smin, smax} = s[:space_m2] || {nil, nil}

        [
          r.rank,
          r.score,
          r.fit,
          s[:name],
          s[:country],
          s[:category],
          s[:branches_n],
          s[:established_n],
          smin,
          smax,
          s[:franchise_fee],
          s[:avg_investment],
          s[:fit_out_cost],
          s[:equipment_cost],
          s[:royalty],
          s[:marketing_fee],
          s[:contract_years],
          s[:payback],
          s[:head_office],
          s[:staff],
          s[:training],
          s[:url],
          r.why_ar,
          "",
          ""
        ]
        |> Enum.map_join(",", &escape/1)
      end)

    # BOM so Excel renders the Arabic columns — repo convention.
    File.write!(path, ["﻿", Enum.join([Enum.join(@headers, ",") | body], "\n"), "\n"])
  end

  defp escape(nil), do: ""

  defp escape(v) do
    s = to_string(v)

    if String.contains?(s, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(s, "\"", "\"\"") <> "\""
    else
      s
    end
  end
end
