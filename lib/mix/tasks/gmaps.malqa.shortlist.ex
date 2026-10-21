defmodule Mix.Tasks.Gmaps.Malqa.Shortlist do
  @moduledoc """
  One ranked shortlist across all three tracks, with every input variable exposed.

      mix gmaps.malqa.shortlist
      mix gmaps.malqa.shortlist --top 40 --min-strength 45
      mix gmaps.malqa.shortlist --site-lat 24.801 --site-lon 46.598

  Ranks by expected value — قوة الفرصة × احتمال الإغلاق — so a reachable good brand
  outranks an unreachable excellent one. No network; re-runs in seconds.
  """

  use Mix.Task

  alias GmapsEx.Malqa.{Contact, Opportunity, Score}
  alias GmapsEx.Whitespace

  @shortdoc "Ranked cross-track shortlist by opportunity strength"

  @out_dir "malqa"

  @switches [
    site_lat: :float,
    site_lon: :float,
    out_dir: :string,
    top: :integer,
    min_strength: :integer,
    per_track: :integer
  ]

  @headers ~w(rank priority track brand verified_absent rank_score strength close_prob activity speed reach
              pull demand crowding kitchen_fit hall_fit asset_fit momentum gap twin
              quality capacity branches avg_rating total_reviews d_min_km category
              cat_outlets_north cat_reviews_per_outlet cat_near_1km
              why_ar channel phone wa_link email website instagram maps_link
              status_owner notes_owner)

  # Kept on one line: an `x`-flag regex broken across lines silently failed to match,
  # which is exactly the kind of filter bug that reads as a scoring problem.
  # Module attributes must also be defined before use — Elixir resolves them at the
  # point of expansion, so a definition further down the file expands to nil.
  @not_a_business ~r/مزار|سياحي|مجمع عمارات|سكني|شقق|فندق|hotel|guest house|دار ضيافة|مستشار|استراحة|شاليه|صالة رياضية|مستشفى|صيدلية|محطة|بنزين|مغسلة|قطع غيار/u

  # Place names that double as shop names. Ten unrelated bakeries in Alexandria all
  # called "المدينة المنورة" are a naming coincidence, not a ten-branch chain, and no
  # statistical guard separates them from a genuine chain that simply has no website.
  @place_names ["المدينة المنورة", "مكة المكرمة", "القاهرة", "الاسكندرية", "الإسكندرية",
                "مصر", "الرياض", "جدة", "طنطا", "المنصورة", "دمشق", "بيروت", "بغداد"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    lat = opts[:site_lat] || 24.798
    lon = opts[:site_lon] || 46.595
    out = opts[:out_dir] || @out_dir
    top = opts[:top] || 60
    per_track = opts[:per_track] || 20
    min_strength = opts[:min_strength] || 30

    Mix.Task.run("app.start")
    File.mkdir_p!(out)

    cat_stats = Whitespace.category_stats(site_lat: lat, site_lon: lon)
    # Computed separately per source: the fuzzy name join is anchored on the source
    # side, so one call cannot answer it for both Egypt and the Saudi cities.
    riyadh =
      Map.merge(
        Whitespace.riyadh_presence("malqa:ksa:%"),
        Whitespace.riyadh_presence("malqa:eg:%")
      )
    act = Whitespace.activity()
    scanned = Whitespace.scanned_names()

    Mix.shell().info(
      ":: #{map_size(cat_stats)} categories · #{map_size(riyadh)} brands already in Riyadh · " <>
        "#{Enum.count(act, fn {_k, a} -> a.has_popular_times end)} with live traffic data"
    )

    candidates =
      [:a, :a2, :ksa, :b]
      |> Enum.flat_map(fn track ->
        track
        |> brands_for(lat, lon)
        |> Enum.map(&Map.put(&1, :riyadh_branches, Map.get(riyadh, &1[:brand_key], 0)))
        |> Enum.map(&Opportunity.with_hay/1)
        |> Enum.filter(&eligible?(&1, track))
        |> Enum.map(&{track, &1})
      end)

    Mix.shell().info(":: #{length(candidates)} eligible candidates across 4 tracks")

    norms = Opportunity.norms(Enum.map(candidates, &elem(&1, 1)), cat_stats)

    scored =
      candidates
      |> Enum.map(fn {track, row} ->
        v = Opportunity.variables(row, track, cat_stats, norms)
        {channel, _note} = Contact.best_channel(row, track)
        {speed, _} = Score.speed(row, track)

        a = Map.get(act, row[:brand_key], %{score: 0.85, has_popular_times: false, has_hours: false})

        %{
          track: track,
          priority: priority(track),
          row: row,
          vars: v,
          strength: Opportunity.strength(v, track),
          close: Opportunity.close_probability(v),
          # Listing health is a mild discount, not a verdict. True trading recency
          # was not obtainable (see Whitespace.activity/1), so this must not carry
          # more weight than the evidence behind it supports.
          rank_score: round(Opportunity.rank_score(v, track) * a.score),
          activity: a.score,
          live: a.has_popular_times,
          verified: verified_absent?(track, row, scanned),
          speed: speed,
          channel: channel,
          why: Opportunity.explain_ar(v, row, track, cat_stats),
          cat: Map.get(cat_stats, row[:top_category], %{})
        }
      end)
      |> Enum.filter(&(&1.strength >= min_strength))
      |> Enum.sort_by(& &1.rank_score, :desc)
      # Dedupe on the *name*, not the key: an under-merge leaves one brand under two
      # keys and it then occupies two slots on a 60-row sheet. Highest score wins.
      |> Enum.uniq_by(&{&1.track, GmapsEx.Brand.normalize_title(&1.row[:brand_name])})

    # Cap per track so one track cannot swamp the sheet, and stratify by decision
    # speed inside each track. Ranking purely on expected value filled all 45 slots
    # with `fast` targets and deleted every strong-but-slower brand from view — which
    # is the wrong trade when the slower track is the fallback if the month runs out.
    # Explicit quota per priority band. Sorting by priority alone let P1 consume the
    # whole sheet, which silently answered "who is nearest" instead of the question
    # actually asked — which was for all three groups, in that order of preference.
    quotas = %{1 => round(top * 0.5), 2 => round(top * 0.25), 3 => top - round(top * 0.5) - round(top * 0.25)}

    shortlist =
      scored
      |> Enum.group_by(& &1.priority)
      |> Enum.flat_map(fn {p, rows} ->
        rows
        |> Enum.group_by(& &1.track)
        |> Enum.flat_map(fn {_t, trows} -> stratify(trows, per_track) end)
        |> Enum.sort_by(&{speed_rank(&1.speed), -&1.rank_score})
        |> Enum.take(Map.get(quotas, p, 0))
      end)
      |> Enum.sort_by(&{&1.priority, speed_rank(&1.speed), -&1.rank_score})
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> Map.put(r, :rank, i) end)

    write_csv(shortlist, Path.join(out, "shortlist.csv"))
    write_board(shortlist, out)
    copy_board_shell(out)

    print(shortlist)
    Mix.shell().info(
      "\n:: #{Path.join(out, "shortlist.csv")}  ·  #{Path.join(out, "shortlist-board.html")}"
    )
  end

  # Two thirds of each track's slots go to targets that can move now; the rest are
  # held for the best of the slower ones, so they are demoted rather than hidden.
  defp stratify(rows, per_track) do
    fast_slots = max(1, round(per_track * 0.65))

    {fast, slower} = Enum.split_with(rows, &(&1.speed == :fast))

    Enum.take(Enum.sort_by(fast, & &1.rank_score, :desc), fast_slots) ++
      Enum.take(Enum.sort_by(slower, & &1.strength, :desc), per_track - fast_slots)
  end

  # Only meaningful for the tracks whose pitch is "you are not in Riyadh yet".
  defp verified_absent?(track, row, scanned) when track in [:ksa, :b] do
    name =
      row[:brand_name]
      |> to_string()
      |> String.split(~r/\s+[-–—|]\s+|\s*\|\s*/u, parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    MapSet.member?(scanned, name)
  end

  defp verified_absent?(_, _, _), do: nil

  defp speed_rank(:fast), do: 0
  defp speed_rank(:medium), do: 1
  defp speed_rank(_), do: 2

  defp brands_for(track, lat, lon) do
    Whitespace.brands(
      site_lat: lat,
      site_lon: lon,
      prefixes: prefixes(track),
      bbox: bbox(track)
    )
  end

  defp prefixes(:a), do: ["malqa:site:%", "malqa:twin:%"]
  defp prefixes(:a2), do: ["malqa:kitchen:%"]
  defp prefixes(:ksa), do: ["malqa:ksa:%"]
  defp prefixes(:b), do: ["malqa:eg:%"]

  # The owner's stated order: people near him in Riyadh first, then brands crushing
  # it elsewhere in Saudi that have no Riyadh branch, then Egyptian brands that are
  # not here either.
  defp priority(:a), do: 1
  defp priority(:a2), do: 1
  defp priority(:ksa), do: 2
  defp priority(:b), do: 3

  @egypt_bbox {21.5, 24.5, 32.5, 37.0}
  @ksa_bbox {16.0, 34.0, 33.0, 56.0}
  defp bbox(:b), do: @egypt_bbox
  defp bbox(_), do: @ksa_bbox

  # Reuse each track's own gates so the shortlist cannot contain anything the track
  # itself would have rejected — daycares, equipment traders, global chains.
  defp eligible?(row, :a), do: Score.track_a(row, %{}) > 0 and not junk?(row)
  defp eligible?(row, :ksa), do: Score.track_ksa(row, %{}) > 0 and not junk?(row)
  defp eligible?(row, :b), do: Score.track_b(row, %{}) > 0 and not junk?(row)

  defp eligible?(row, :a2) do
    Score.track_a2(row, %{}) > 0 and food_producer?(row) and fundable?(row) and
      not junk?(row)
  end

  @doc """
  Rows that are not businesses of the kind being targeted at all.

  Two separate problems. Some categories simply are not food operators — a tourist
  attraction, a residential compound, a guest house that matched on "ضيافة". And
  some "chains" are name collisions: ten unrelated bakeries in Alexandria all called
  "المدينة المنورة" are not a ten-branch brand. A real chain has either a website
  somewhere or meaningful review mass per site; a collision has neither.
  """
  defp junk?(row) do
    hay =
      [row[:top_category], row[:brand_name]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    wrong_kind = Regex.match?(@not_a_business, hay)

    wrong_kind or name_collision?(row)
  end

  defp name_collision?(row) do
    n = row[:branches] || 0
    reviews = row[:total_reviews] || 0
    sites = row[:distinct_sites] || 0
    name = String.trim(to_string(row[:brand_name]))

    (n >= 3 and sites == 0 and reviews / max(n, 1) < 50) or
      (n >= 3 and name in @place_names)
  end

  # A wedding-stage decorator and a university function hall both match "حفلات" and
  # neither one produces food. The kitchen is the asset; the buyer has to cook.
  defp food_producer?(row) do
    hay =
      [row[:top_category], row[:brand_name]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    not Regex.match?(
      ~r/كوشه|كوشة|تنسيق|ديكور|تأجير|جامعة|مدرسة|قاعة احتفالات|زهور|ورد|تصوير|كراسي|عطاره|عطارة|بهارات|توابل|مستلزمات/u,
      hay
    )
  end

  # A تنازل is a six-figure cash deal. A single counter with 80 reviews and no
  # registered entity is not that buyer, whatever its concept fit says.
  defp fundable?(row) do
    reviews = row[:total_reviews] || 0
    branches = row[:branches] || 0
    entity = GmapsEx.Malqa.Opportunity.entity(row) >= 0.6

    # A registered catering/entity qualifies on its own: its review count reflects
    # who its customers are, not how big it is.
    entity or branches >= 2 or reviews >= 400
  end

  defp print(rows) do
    Mix.shell().info("\n#   أول  trk  سرعة    قوة  احتمال  نشاط  ترتيب  البراند")

    rows
    |> Enum.take(30)
    |> Enum.each(fn r ->
      Mix.shell().info(
        String.pad_leading(to_string(r.rank), 2) <>
          "   P" <> to_string(r.priority) <>
          "  " <> String.pad_trailing(to_string(r.track), 4) <>
          String.pad_trailing(to_string(r.speed), 8) <>
          String.pad_leading(to_string(r.strength), 4) <>
          String.pad_leading(:erlang.float_to_binary(r.close, decimals: 2), 8) <>
          String.pad_leading(if(r.live, do: "حي", else: "·"), 6) <>
          String.pad_leading(to_string(r.rank_score), 7) <>
          "  " <> truncate(r.row[:brand_name], 30)
      )
    end)
  end

  defp truncate(nil, _), do: ""
  defp truncate(s, n), do: if(String.length(s) > n, do: String.slice(s, 0, n - 1) <> "…", else: s)

  defp write_csv(rows, path) do
    body =
      Enum.map(rows, fn r ->
        row = r.row
        v = r.vars
        c = r.cat

        [
          r.rank,
          r.priority,
          r.track,
          row[:brand_name],
          verified_label(r.verified),
          r.rank_score,
          r.strength,
          r.close,
          f(r.activity),
          r.speed,
          f(v.reach),
          f(v.pull),
          f(v.demand),
          f(v.crowding),
          f(v.kitchen_fit),
          f(v.hall_fit),
          f(v.asset_fit),
          f(v.momentum),
          f(v.gap),
          f(v.twin),
          f(v.quality),
          f(v.capacity),
          row[:branches],
          r1(row[:w_rating]),
          row[:total_reviews],
          r1(row[:d_min]),
          row[:top_category],
          Map.get(c, :outlets),
          c |> Map.get(:reviews_per_outlet) |> rnd(),
          Map.get(c, :near_1km),
          r.why,
          r.channel,
          Contact.display(row[:phone]),
          Contact.wa_link(row[:phone]),
          first(row[:emails]),
          Contact.real_website(row[:website]),
          Contact.instagram_handle(row[:website]),
          row[:link],
          "",
          ""
        ]
        |> Enum.map_join(",", &esc/1)
      end)

    File.write!(path, ["﻿", Enum.join([Enum.join(@headers, ",") | body], "\n"), "\n"])
  end

  defp write_board(rows, out) do
    data =
      Enum.map(rows, fn r ->
        row = r.row

        %{
          r: r.rank,
          tr: to_string(r.track),
          g: grade(r.rank_score),
          s: r.rank_score,
          st: r.strength,
          cp: r.close,
          pr: r.priority,
          act: r.activity,
          live: r.live,
          vf: r.verified,
          n: row[:brand_name],
          b: row[:branches],
          rt: r1(row[:w_rating]),
          rv: row[:total_reviews],
          d: r1(row[:d_min]),
          cat: row[:top_category],
          why: r.why,
          ch: to_string(r.channel),
          chn: "",
          p: Contact.display(row[:phone]),
          wa: Contact.wa_link(row[:phone]),
          e: first(row[:emails]),
          w: Contact.real_website(row[:website]),
          ig: Contact.instagram_handle(row[:website]),
          m: row[:link]
        }
      end)

    File.write!(
      Path.join(out, "shortlist-data.js"),
      ["window.TARGETS = ", Jason.encode_to_iodata!(data), ";\n"]
    )
  end

  # `rank` writes the full 636-row board and `shortlist` writes these 45. Pointing
  # both at board-data.js meant whichever ran last silently decided what the board
  # showed. Separate files, separate pages.
  defp copy_board_shell(out) do
    src = Path.join(out, "board.html")
    dest = Path.join(out, "shortlist-board.html")

    case File.read(src) do
      {:ok, html} ->
        File.write!(
          dest,
          html
          |> String.replace("board-data.js", "shortlist-data.js")
          |> String.replace(
            "<title>أهداف الملقا — أنس بن مالك</title>",
            "<title>القائمة المرشّحة — الملقا</title>"
          )
          |> String.replace(
            "أهداف الملقا — مطبخ إنتاج + صالة ١٨٠–٢٠٠ م²",
            "القائمة المرشّحة — مرتّبة بقوة الفرصة × احتمال الإغلاق"
          )
          |> String.replace("malqa_targets_v1", "malqa_shortlist_v1")
        )

      _ ->
        Mix.shell().error(":: board.html not found — run `mix gmaps.malqa.rank` first")
    end
  end

  defp verified_label(nil), do: ""
  defp verified_label(true), do: "تم التحقق"
  defp verified_label(false), do: "غير متحقق"

  defp grade(s) when s >= 55, do: "A+"
  defp grade(s) when s >= 40, do: "A"
  defp grade(s) when s >= 25, do: "B"
  defp grade(_), do: "C"

  defp f(v) when is_number(v), do: Float.round(v / 1, 2)
  defp f(_), do: 0.0

  defp r1(nil), do: nil
  defp r1(%Decimal{} = d), do: d |> Decimal.to_float() |> Float.round(1)
  defp r1(n) when is_number(n), do: Float.round(n / 1, 1)

  defp rnd(nil), do: nil
  defp rnd(n) when is_number(n), do: round(n)

  defp first(nil), do: nil
  defp first([]), do: nil
  defp first([e | _]), do: e
  defp first(e), do: e

  defp esc(nil), do: ""

  defp esc(v) do
    s = to_string(v)

    if String.contains?(s, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end
end
