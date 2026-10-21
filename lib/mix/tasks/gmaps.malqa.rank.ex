defmodule Mix.Tasks.Gmaps.Malqa.Rank do
  @moduledoc """
  Score, rank and export the Al Malqa target lists. No network — seconds, re-runnable.

      mix gmaps.malqa.rank
      mix gmaps.malqa.rank --site-lat 24.798 --site-lon 46.595
      mix gmaps.malqa.rank --track a --top 120

  Because this reads only the database, scoring can be re-tuned and the whole list
  re-ranked without touching Google again.
  """

  use Mix.Task

  alias GmapsEx.Malqa.{Contact, Districts, Score}
  alias GmapsEx.Whitespace

  @shortdoc "Rank and export the Al Malqa target lists"

  @out_dir "malqa"

  @switches [
    site_lat: :float,
    site_lon: :float,
    out_dir: :string,
    track: :string,
    top: :integer,
    min_score: :integer,
    new_branch_reviews: :integer,
    html: :boolean
  ]

  @headers ~w(rank track grade score speed speed_note brand branches avg_rating
              total_reviews new_branch_pct twin_pct d_min_km nearest_district category
              price_range why_ar channel channel_note phone wa_link email website
              instagram maps_link districts member_titles status_owner notes_owner)

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    lat = opts[:site_lat] || 24.798
    lon = opts[:site_lon] || 46.595
    out = opts[:out_dir] || @out_dir
    tracks = (opts[:track] || "a,a2") |> String.split(",", trim: true)

    Mix.Task.run("app.start")
    File.mkdir_p!(out)

    Mix.shell().info(":: site #{lat}, #{lon}")

    density = category_density(lat, lon)
    write_category_whitespace(lat, lon, out)

    ctx = %{
      category_density: density,
      ksa: Whitespace.ksa_presence_fuzzy(),
      franex: load_franex()
    }

    results =
      for t <- tracks, into: %{} do
        track = String.to_atom(t)

        brands =
          Whitespace.brands(
            site_lat: lat,
            site_lon: lon,
            prefixes: stage_prefixes(track),
            bbox: bbox(track),
            new_branch_reviews: opts[:new_branch_reviews] || 60
          )

        Mix.shell().info(":: track #{t}: #{length(brands)} brands in scope")
        rows = rank(brands, track, ctx, opts)
        write_csv(rows, Path.join(out, "track-#{t}.csv"))
        {track, rows}
      end

    combined =
      results
      |> Enum.flat_map(fn {_t, rows} -> rows end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} -> %{r | rank: i} end)

    write_csv(combined, Path.join(out, "all-targets.csv"))
    if opts[:html] != false, do: write_board(combined, out)

    Enum.each(results, fn {track, rows} ->
      Mix.shell().info("\n:: TRACK #{String.upcase(to_string(track))} — #{length(rows)} targets")
      rows |> Enum.take(12) |> Enum.each(&preview/1)
    end)

    Mix.shell().info("\n:: #{Path.join(out, "all-targets.csv")}")
  end

  defp rank(all, track, ctx, opts) do
    min_score = opts[:min_score] || 35
    top = opts[:top] || 300

    all
    |> Enum.map(fn row ->
      row = enrich(row, track, ctx)
      score = apply(Score, score_fn(track), [row, ctx])
      {channel, note} = Contact.best_channel(row, track)
      {speed, speed_note} = Score.speed(row, track)

      %{
        rank: 0,
        track: track,
        score: score,
        grade: "C",
        row: row,
        channel: channel,
        channel_note: note,
        speed: speed,
        speed_note: speed_note,
        why: Score.why_ar(row, track)
      }
    end)
    |> Enum.filter(&(&1.score >= min_score))
    |> Enum.sort_by(fn r -> {-r.score, speed_order(r.speed)} end)
    |> Enum.take(top)
    |> then(fn rows ->
      total = length(rows)

      rows
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        %{r | rank: i + 1, grade: Score.grade_by_rank(i, total)}
      end)
    end)
  end

  # Track B needs two facts the Egypt harvest cannot supply on its own: how many
  # branches the brand already has inside KSA, and whether it turns up in the
  # franchise directory asking for a Saudi partner.
  defp enrich(row, :b, ctx) do
    ksa = Map.get(ctx.ksa, row[:brand_key], 0)
    fx = match_franex(row[:brand_name], ctx.franex)

    row
    |> Map.put(:ksa_branches, ksa)
    |> Map.put(:franex, fx != nil)
    |> Map.put(:space_fit, fx != nil and fx["space_fit"] == true)
    |> Map.put(:franchise_signal, fx != nil)
  end

  defp enrich(row, _track, _ctx), do: row

  defp load_franex do
    case File.read(Path.join(@out_dir, "franex.json")) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  # Franex names are Latin, the Maps brand name is often Arabic; only a confident
  # substring match counts, because a false positive here inflates a tier.
  defp match_franex(nil, _), do: nil

  defp match_franex(brand, sheets) do
    b = brand |> String.downcase() |> String.trim()

    Enum.find(sheets, fn sh ->
      n = sh["name"] |> to_string() |> String.downcase() |> String.trim()

      String.length(n) >= 4 and
        (String.contains?(b, n) or String.contains?(n, b))
    end)
  end

  # Egypt vs Saudi by longitude — the two do not overlap.
  @egypt_bbox {21.5, 24.5, 32.5, 37.0}
  @ksa_bbox {16.0, 34.0, 33.0, 56.0}

  defp bbox(:b), do: @egypt_bbox
  defp bbox(_), do: @ksa_bbox

  # Each track reads only the stages that were harvested for it.
  defp stage_prefixes(:a), do: ["malqa:site:%", "malqa:twin:%"]
  defp stage_prefixes(:a2), do: ["malqa:kitchen:%"]
  defp stage_prefixes(:b), do: ["malqa:eg:%"]
  defp stage_prefixes(_), do: ["malqa:%"]

  defp speed_order(:fast), do: 0
  defp speed_order(:medium), do: 1
  defp speed_order(_), do: 2

  defp score_fn(:a), do: :track_a
  defp score_fn(:a2), do: :track_a2
  defp score_fn(:b), do: :track_b
  defp score_fn(_), do: :track_a

  @doc """
  The category white-space map: what already trades around the unit, and which
  categories are strong across Riyadh but absent here.

  This is the sheet that answers "why should a brand take this spot" with numbers,
  and it is also the honest answer to "isn't Anas Ibn Malik already saturated?" —
  saturation is only an objection where the *same* concept is already next door.
  """
  defp write_category_whitespace(lat, lon, out) do
    near = Whitespace.near_site(site_lat: lat, site_lon: lon, radius_km: 1.0)
    present = MapSet.new(near.categories, & &1.category)

    sql = """
    SELECT coalesce(categories[1], category) AS cat, count(*) n,
           round(avg(review_rating)::numeric, 2) r, sum(review_count) rv
      FROM places
     WHERE input_id LIKE ANY($1::text[])
       AND coalesce(categories[1], category) IS NOT NULL
     GROUP BY 1 HAVING count(*) >= 8
     ORDER BY count(*) DESC
    """

    %{rows: rows} = GmapsEx.Repo.query!(sql, [["malqa:site:%", "malqa:twin:%"]])

    header = "category,near_1km,near_800m,riyadh_total,riyadh_avg_rating,riyadh_reviews,verdict"

    body =
      Enum.map(rows, fn [cat, n, r, rv] ->
        here = Enum.find(near.categories, &(&1.category == cat))
        n1 = if here, do: here.n_radius, else: 0
        n8 = if here, do: here.n_800m, else: 0

        verdict =
          cond do
            not MapSet.member?(present, cat) -> "فجوة — غير موجود في نطاق كم"
            n1 >= 5 -> "مشبع — تجنّب"
            n1 >= 3 -> "مزدحم"
            true -> "خفيف — فرصة"
          end

        Enum.map_join([cat, n1, n8, n, r, rv, verdict], ",", &escape/1)
      end)

    File.write!(
      Path.join(out, "category-whitespace.csv"),
      ["\uFEFF", Enum.join([header | body], "\n"), "\n"]
    )

    gaps = Enum.count(body, &String.contains?(&1, "فجوة"))
    Mix.shell().info(":: category map → #{Path.join(out, "category-whitespace.csv")} (#{gaps} gaps)")
  end

  # How many places of each category already sit within 1 km of the unit.
  defp category_density(lat, lon) do
    Whitespace.near_site(site_lat: lat, site_lon: lon, radius_km: 1.0).categories
    |> Map.new(fn c -> {c.category, c.n_radius} end)
  end

  defp preview(r) do
    row = r.row

    Mix.shell().info(
      "   #{String.pad_leading(to_string(r.score), 3)} #{String.pad_trailing(r.grade, 3)} " <>
        "#{String.pad_trailing(truncate(row[:brand_name], 28), 30)} " <>
        "#{String.pad_leading(to_string(row[:branches]), 3)}fr  " <>
        "#{r.why}"
    )
  end

  defp truncate(nil, _), do: ""
  defp truncate(s, n), do: if(String.length(s) > n, do: String.slice(s, 0, n - 1) <> "…", else: s)

  defp write_csv(rows, path) do
    body =
      Enum.map(rows, fn r ->
        row = r.row
        email = first(row[:emails])

        [
          r.rank,
          r.track,
          r.grade,
          r.score,
          r.speed,
          r.speed_note,
          row[:brand_name],
          row[:branches],
          round1(row[:w_rating]),
          row[:total_reviews],
          pct(row[:new_branch_frac]),
          pct(row[:twin_frac]),
          round1(row[:d_min]),
          Districts.tag_for_name(row[:nearest_district]) || row[:nearest_district],
          row[:top_category],
          row[:price_range],
          r.why,
          r.channel,
          r.channel_note,
          Contact.display(row[:phone]),
          Contact.wa_link(row[:phone]),
          email,
          Contact.real_website(row[:website]),
          Contact.instagram_handle(row[:website]),
          row[:link],
          Enum.join(row[:districts] || [], " / "),
          row[:member_titles] |> List.wrap() |> Enum.take(8) |> Enum.join(" / "),
          "",
          ""
        ]
        |> Enum.map_join(",", &escape/1)
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
          g: r.grade,
          s: r.score,
          sp: to_string(r.speed),
          spn: r.speed_note,
          n: row[:brand_name],
          b: row[:branches],
          rt: round1(row[:w_rating]),
          rv: row[:total_reviews],
          d: round1(row[:d_min]),
          cat: row[:top_category],
          why: r.why,
          ch: to_string(r.channel),
          chn: r.channel_note,
          p: Contact.display(row[:phone]),
          wa: Contact.wa_link(row[:phone]),
          e: first(row[:emails]),
          w: Contact.real_website(row[:website]),
          ig: Contact.instagram_handle(row[:website]),
          m: row[:link]
        }
      end)

    File.write!(
      Path.join(out, "board-data.js"),
      ["window.TARGETS = ", Jason.encode_to_iodata!(data), ";\n"]
    )

    File.write!(Path.join(out, "board.html"), board_html())
  end

  defp first(nil), do: nil
  defp first([]), do: nil
  defp first([e | _]), do: e
  defp first(e), do: e

  defp round1(nil), do: nil
  defp round1(%Decimal{} = d), do: d |> Decimal.to_float() |> Float.round(1)
  defp round1(n) when is_number(n), do: Float.round(n / 1, 1)

  defp pct(nil), do: 0
  defp pct(%Decimal{} = d), do: d |> Decimal.to_float() |> Kernel.*(100) |> round()
  defp pct(n) when is_number(n), do: round(n * 100)

  defp escape(nil), do: ""

  defp escape(v) do
    s = to_string(v)

    if String.contains?(s, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(s, "\"", "\"\"") <> "\"",
      else: s
  end

  defp board_html do
    """
    <!doctype html>
    <html lang="ar" dir="rtl"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>أهداف الملقا — أنس بن مالك</title>
    <style>
      :root{--bg:#0f1115;--card:#171a21;--line:#262b36;--fg:#e7eaf0;--mut:#9aa3b2;--acc:#4a9eff}
      *{box-sizing:border-box}
      body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,"Segoe UI",Tahoma,sans-serif}
      header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:12px 16px;z-index:5}
      h1{margin:0 0 8px;font-size:17px}
      .f{display:flex;gap:6px;flex-wrap:wrap}
      .f button{background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:999px;padding:5px 12px;font-size:13px;cursor:pointer}
      .f button.on{background:var(--acc);border-color:var(--acc);color:#fff}
      main{padding:12px 16px;display:grid;gap:10px}
      .c{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}
      .t{display:flex;justify-content:space-between;gap:8px;align-items:flex-start}
      .nm{font-weight:600;font-size:15px}
      .sc{font-variant-numeric:tabular-nums;color:var(--acc);font-weight:700;white-space:nowrap}
      .why{color:var(--mut);font-size:13px;margin:6px 0 10px}
      .a{display:flex;gap:8px;flex-wrap:wrap}
      .a a{text-decoration:none;border:1px solid var(--line);border-radius:8px;padding:6px 10px;color:var(--fg);font-size:13px}
      .a a.w{background:#1d7a3f;border-color:#1d7a3f;color:#fff}
      .st{margin-top:10px;display:flex;gap:6px;flex-wrap:wrap}
      .st button{flex:1;min-width:72px;background:transparent;color:var(--mut);border:1px solid var(--line);border-radius:8px;padding:6px;font-size:12px;cursor:pointer}
      .st button.on{background:var(--acc);border-color:var(--acc);color:#fff}
      .badge{font-size:11px;border:1px solid var(--line);border-radius:6px;padding:2px 6px;color:var(--mut)}
      .sum{color:var(--mut);font-size:12px;margin-top:6px}
    </style></head><body>
    <header>
      <h1>أهداف الملقا — مطبخ إنتاج + صالة ١٨٠–٢٠٠ م²</h1>
      <div class="f" id="filters"></div>
      <div class="sum" id="sum"></div>
    </header>
    <main id="list"></main>
    <script src="board-data.js"></script>
    <script>
    // Per-viewer only; the CSV is the shared artifact.
    var LS="malqa_targets_v1";
    var state=JSON.parse(localStorage.getItem(LS)||"{}");
    var TRACKS={a:"سلاسل الرياض",a2:"مشتري المطبخ",b:"براندات مصرية"};
    var STATUSES=["لم يتم","تم التواصل","رد","مهتم","مرفوض"];
    var filter="all";
    function save(){try{localStorage.setItem(LS,JSON.stringify(state))}catch(e){}}
    function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]})}
    function render(){
      var fs=document.getElementById("filters");
      var keys=["all"].concat(Object.keys(TRACKS));
      fs.innerHTML=keys.map(function(k){
        return '<button data-k="'+k+'" class="'+(filter===k?"on":"")+'">'+(k==="all"?"الكل":TRACKS[k])+'</button>'}).join("");
      fs.querySelectorAll("button").forEach(function(b){b.onclick=function(){filter=b.dataset.k;render()}});
      var rows=TARGETS.filter(function(t){return filter==="all"||t.tr===filter});
      var done=rows.filter(function(t){return state[t.n]&&state[t.n]!=="لم يتم"}).length;
      document.getElementById("sum").textContent=rows.length+" هدف · تم التواصل مع "+done;
      document.getElementById("list").innerHTML=rows.map(function(t){
        var acts=[];
        if(t.wa)acts.push('<a class="w" href="'+t.wa+'" target="_blank">واتساب</a>');
        if(t.p&&!t.wa)acts.push('<a href="tel:+'+esc(t.p).replace(/[^0-9]/g,"")+'">اتصال</a>');
        if(t.e)acts.push('<a href="mailto:'+esc(t.e)+'">إيميل</a>');
        if(t.ig)acts.push('<a href="https://instagram.com/'+esc(t.ig)+'" target="_blank">إنستغرام</a>');
        if(t.w)acts.push('<a href="'+esc(t.w)+'" target="_blank">الموقع</a>');
        if(t.m)acts.push('<a href="'+esc(t.m)+'" target="_blank">الخريطة</a>');
        var cur=state[t.n]||"لم يتم";
        return '<div class="c"><div class="t"><div><div class="nm">'+esc(t.n)+'</div>'+
          '<span class="badge">'+esc(TRACKS[t.tr]||t.tr)+'</span> <span class="badge">'+esc(t.g)+'</span>'+
          (t.cat?' <span class="badge">'+esc(t.cat)+'</span>':'')+'</div>'+
          '<div class="sc">'+t.s+'</div></div>'+
          '<div class="why">'+esc(t.why)+'</div>'+
          '<div class="a">'+acts.join("")+'</div>'+
          '<div class="st" data-n="'+esc(t.n)+'">'+STATUSES.map(function(s){
            return '<button class="'+(cur===s?"on":"")+'" data-s="'+s+'">'+s+'</button>'}).join("")+'</div></div>';
      }).join("");
      document.querySelectorAll(".st").forEach(function(g){
        g.querySelectorAll("button").forEach(function(b){
          b.onclick=function(){state[g.dataset.n]=b.dataset.s;save();render()}})});
    }
    render();
    </script></body></html>
    """
  end
end
