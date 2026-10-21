defmodule Mix.Tasks.Gmaps.Malqa.Brands do
  @moduledoc """
  Derive brands from the harvested places, audit the grouping, and emit the
  brand-name queries for the citywide scan.

      mix gmaps.malqa.brands                  # backfill brand_key/brand_name/district
      mix gmaps.malqa.brands --audit          # write the audit CSV
      mix gmaps.malqa.brands --alias-report   # near-miss pairs to merge by hand
      mix gmaps.malqa.brands --emit-queries   # brandscan-queries.txt for the harvest

  No network. Re-run it after every change to the normalizer or the alias table —
  it re-keys the whole set in seconds, which is what makes the audit loop usable.
  """

  use Mix.Task

  alias GmapsEx.Whitespace

  @shortdoc "Derive and audit brands for the Al Malqa analysis"

  @out_dir "malqa"

  @switches [
    prefix: :string,
    audit: :boolean,
    top: :integer,
    alias_report: :boolean,
    emit_queries: :boolean,
    min_branches: :integer,
    max_queries: :integer,
    out_dir: :string,
    queries_file: :string,
    min_reviews: :integer,
    skip_backfill: :boolean,
    check: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    prefix = opts[:prefix] || "malqa:%"
    out = opts[:out_dir] || @out_dir
    Mix.Task.run("app.start")
    File.mkdir_p!(out)

    unless opts[:skip_backfill] do
      r = Whitespace.backfill(prefix)
      Mix.shell().info(":: keyed #{r.updated} of #{r.scanned} places")
    end

    if opts[:check], do: check(prefix)
    if opts[:audit], do: audit(prefix, out, opts[:top] || 120)
    if opts[:alias_report], do: alias_report(prefix, out)
    if opts[:emit_queries], do: emit_queries(prefix, out, opts)
  end

  # The two automated alarms: over-merge and a broken district model.
  defp check(prefix) do
    d = Whitespace.district_agreement(prefix)

    Mix.shell().info(
      ":: district model — #{d.agreement}% agreement with addresses (#{d.comparable} comparable), " <>
        "#{d.other_rate}% unassigned"
    )

    if d.agreement < 85.0 do
      Mix.shell().error(
        ":: WARNING district agreement below 85% — twin-district affinity is unreliable"
      )
    end

    brands = Whitespace.brands(prefix: prefix)
    suspicious = Enum.filter(brands, &((&1[:distinct_sites] || 0) > 1))

    Mix.shell().info(
      ":: #{length(brands)} brands; #{length(suspicious)} have >1 distinct website (possible over-merge)"
    )

    suspicious
    |> Enum.sort_by(&(-(&1[:branches] || 0)))
    |> Enum.take(8)
    |> Enum.each(fn b ->
      Mix.shell().info("   #{b[:brand_name]} — #{b[:branches]} branches, #{b[:distinct_sites]} sites")
    end)
  end

  defp audit(prefix, out, top) do
    path = Path.join(out, "brand-audit.csv")

    rows =
      Whitespace.brands(prefix: prefix)
      |> Enum.sort_by(&(-(&1[:branches] || 0)))
      |> Enum.take(top)
      |> Enum.map(fn b ->
        [
          b[:brand_key],
          b[:brand_name],
          b[:branches],
          b[:distinct_sites],
          b[:total_reviews],
          b[:website],
          b[:districts] |> List.wrap() |> Enum.join(" / "),
          b[:member_titles] |> List.wrap() |> Enum.join(" | ")
        ]
        |> Enum.map_join(",", &esc/1)
      end)

    header = "brand_key,brand_name,branches,distinct_sites,total_reviews,website,districts,member_titles"
    File.write!(path, ["﻿", Enum.join([header | rows], "\n"), "\n"])
    Mix.shell().info(":: audit → #{path} (#{length(rows)} brands — eyeball member_titles)")
  end

  defp alias_report(prefix, out) do
    path = Path.join(out, "alias-candidates.csv")
    cands = Whitespace.alias_candidates(prefix)

    rows =
      Enum.map(cands, fn c ->
        Enum.map_join([c.key_a, c.name_a, c.key_b, c.name_b, c.similarity], ",", &esc/1)
      end)

    File.write!(path, ["﻿", Enum.join(["key_a,name_a,key_b,name_b,similarity" | rows], "\n"), "\n"])
    Mix.shell().info(":: #{length(cands)} near-miss pairs → #{path}")
  end

  @doc """
  Emit brand names to search citywide.

  The geographic harvest only sees the districts it covered, so a brand's branch
  count out of it is a lower bound. Searching the brand *name* from a handful of
  low-zoom anchors pulls its branches from across Riyadh in a few requests — far
  cheaper than tiling the whole city at F&B density.
  """
  defp emit_queries(prefix, out, opts) do
    min_branches = opts[:min_branches] || 2
    min_reviews = opts[:min_reviews] || 0
    max_q = opts[:max_queries] || 400
    path = Path.join(out, opts[:queries_file] || "brandscan-queries.txt")

    names =
      Whitespace.brands(prefixes: String.split(prefix, ",", trim: true))
      |> Enum.filter(fn b ->
        (b[:branches] || 0) >= min_branches and
          (b[:total_reviews] || 0) >= min_reviews and
          b[:brand_name] not in [nil, ""] and
          String.length(b[:brand_name]) >= 3
      end)
      |> Enum.sort_by(&(-(&1[:total_reviews] || 0)))
      |> Enum.take(max_q)
      |> Enum.map(&clean_query(&1[:brand_name]))
      |> Enum.uniq()

    File.write!(path, Enum.join(names, "\n") <> "\n")
    Mix.shell().info(":: #{length(names)} brand queries → #{path}")
  end

  # A Maps query wants the brand, not the branch decoration.
  defp clean_query(name) do
    name
    |> String.split(~r/\s+[-–—|]\s+|\s*\|\s*/u, parts: 2)
    |> hd()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp esc(nil), do: ""

  defp esc(v) do
    s = to_string(v)

    if String.contains?(s, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end
end
