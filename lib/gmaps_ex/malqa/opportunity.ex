defmodule GmapsEx.Malqa.Opportunity do
  @moduledoc """
  Cross-track shortlisting: how strong is the opportunity, and what are the odds it
  closes.

  The per-track scores in `GmapsEx.Malqa.Score` are not comparable with each other —
  a 77 on the kitchen track and a 77 on the white-space track measure different
  things. This module puts every candidate on one scale by separating two questions
  that the per-track scores conflate:

    * **قوة الفرصة (0–100)** — how good this deal is *if* it happens. Built from
      unmet demand for their concept at this location, how well the asset matches
      what they need, their own expansion momentum, the geographic gap, brand
      quality, and whether they can fund it.
    * **احتمال الإغلاق (0–1)** — the odds of it happening inside the deadline.
      Reachability times decision latency. Nothing else moves this.

  Ranking multiplies them, because an 18-day deadline makes an unreachable perfect
  brand worth less than a reachable good one. Every input is exposed as its own
  column so the ranking can be argued with rather than trusted.
  """

  alias GmapsEx.Malqa.{Contact, Districts}

  @type vars :: %{atom() => float()}

  # How much of this concept's cost sits in the kitchen rather than the dining room.
  # The production kitchen is the asset's scarce half, so a concept that needs one is
  # worth far more here than a concept that could trade out of a serving counter.
  @kitchen_heavy ~w(بوفيه إعاشة اعاشة تموين كاترينج catering مطبخ مركزي central
                    مشويات مصرية هندية باكستانية أرز فطائر فطير كشري ولائم حفلات
                    ضيافة مطاعم وجبات مصنع إنتاج مخبز تصنيع الأغذية توريد)
  @kitchen_light ~w(كافيه مقهى قهوة coffee cafe عصير عصائر بوظة آيس شيكولاتة
                    دونات كعك حلويات متجر juice ice)

  # The unit is a 200 m² ground-floor hall plus a 150 m² mezzanine (سندرة) — 350 m²
  # if the mezzanine is built out. In Saudi F&B a mezzanine is not dead space: it is
  # where the family section goes, which is precisely what a full-service family
  # restaurant needs and what a takeaway counter cannot use at all.
  @unit_ground_m2 200
  @unit_total_m2 350

  # Concepts that use a full-service ground floor *and* can put a family section
  # upstairs — these gain the most from the mezzanine.
  @hall_family ~w(عائلي مأكولات مشويات بوفيه شرائح اللحم بحرية تركية مصرية هندية
                  إيرانية آسيوية يابانية إيطالية لبنانية سوري شامي أرز صحية مطعم راق
                  ستيك steak family)
  # Concepts that trade from a counter: a second floor is cost, not capacity.
  @hall_counter ~w(متجر محل عربة كشك عربية توصيل دونات شيكولاتة بوظة عصير
                   kiosk takeaway)

  @doc """
  Compute every input variable for one candidate.

  `cat_stats` comes from `GmapsEx.Whitespace.category_stats/1`; `norms` carries the
  population maxima used to scale the unbounded variables.
  """
  @spec variables(map(), atom(), map(), map()) :: vars()
  def variables(row, track, cat_stats, norms) do
    cat = row[:top_category]
    st = Map.get(cat_stats, cat, %{outlets: 0, reviews_per_outlet: 0.0, near_1km: 0})

    %{
      demand: demand(st, norms),
      crowding: crowding(st),
      pull: pull(st, norms),
      kitchen_fit: kitchen_fit(row),
      hall_fit: hall_fit(row),
      asset_fit: asset_fit(row),
      momentum: momentum(row),
      gap: gap(row, track),
      twin: clamp(row[:twin_frac] || 0.0),
      quality: quality(row),
      entity: entity(row),
      proven: proven(row),
      capacity: capacity(row, norms, track),
      reach: reach(row),
      speed: speed_factor(row, track)
    }
  end

  # Revealed demand per unit of supply: a category with few outlets and a huge review
  # mass is one the market wants more of.
  defp demand(st, norms) do
    clamp(st.reviews_per_outlet / max(norms.max_rpo, 1.0))
  end

  # How many of the same concept already trade inside the catchment.
  defp crowding(st), do: clamp(st.near_1km / 6.0)

  # The headline variable: unmet demand for *this concept* at *this address*.
  defp pull(st, norms) do
    clamp(demand(st, norms) / (1.0 + st.near_1km * 0.6))
  end

  @doc "How much of this concept's cost lives in the kitchen (0–1)."
  @spec kitchen_fit(map()) :: float()
  def kitchen_fit(row) do
    hay = hay(row)

    cond do
      Enum.any?(@kitchen_heavy, &String.contains?(hay, &1)) -> 1.0
      Enum.any?(@kitchen_light, &String.contains?(hay, &1)) -> 0.25
      true -> 0.6
    end
  end

  @doc """
  Does the unit's shape suit this concept (0–1)?

  Scored against 200 m² on the ground today and 350 m² with the mezzanine built out.
  A counter-service brand is marked down not because it is a weak brand but because
  it would be paying for 150 m² it has no use for.
  """
  @spec hall_fit(map()) :: float()
  def hall_fit(row) do
    hay = hay(row)

    cond do
      Enum.any?(@hall_family, &String.contains?(hay, &1)) -> 1.0
      Enum.any?(@hall_counter, &String.contains?(hay, &1)) -> 0.3
      String.contains?(hay, "كافيه") or String.contains?(hay, "مقهى") -> 0.6
      true -> 0.7
    end
  end

  @doc "The unit as advertised: ground floor, and total with the mezzanine."
  @spec unit_area() :: {pos_integer(), pos_integer()}
  def unit_area, do: {@unit_ground_m2, @unit_total_m2}

  # The asset is a production kitchen first and a hall second, so weight it that way.
  defp asset_fit(row), do: clamp(0.6 * kitchen_fit(row) + 0.4 * hall_fit(row))

  # A brand whose branches are mostly young is a brand still signing leases.
  defp momentum(row) do
    n = row[:branches] || 0
    if n < 3, do: 0.35, else: clamp((row[:new_branch_frac] || 0.0) / 0.35)
  end

  # Distance to their nearest branch. Zero when they are already here; the white-space
  # gate has usually excluded those already, but the kitchen track has no such gate.
  defp gap(_row, :a2), do: 0.5
  defp gap(_row, :ksa), do: 0.9

  defp gap(row, _) do
    case row[:d_min] do
      nil -> 0.4
      d when d < 1.5 -> 0.0
      d when d < 3.0 -> 0.35
      d when d < 6.0 -> 0.8
      d when d < 14.0 -> 1.0
      _ -> 0.7
    end
  end

  defp quality(row) do
    case row[:w_rating] do
      nil -> 0.3
      r -> clamp((r / 1 - 3.2) / 1.3)
    end
  end

  @doc """
  Is this a registered trading entity rather than a one-man shop?

  A تنازل is a six-figure cash transaction. "شركة أنوفا لخدمات الإعاشة" can sign one;
  a single unregistered bakery counter usually cannot, however busy it is. The legal
  form in the trading name is the only solvency signal Maps carries, and it separates
  the two populations cleanly.
  """
  @spec entity(map()) :: float()
  def entity(row) do
    hay = hay(row)

    cond do
      Regex.match?(~r/شركة|مؤسسة|مجموعة|company|est\b|co\.|corp|group|holding/iu, hay) -> 1.0
      Regex.match?(~r/مصنع|مخابز|مطابخ|مركز|factory/iu, hay) -> 0.6
      true -> 0.0
    end
  end

  @doc """
  Have they already opened a second site?

  Opening branch two is the hard one. An operator who has done it has financing, a
  manager bench and an appetite for another — the single best predictor that they
  will take on one more.
  """
  @spec proven(map()) :: float()
  def proven(row) do
    case row[:branches] || 0 do
      n when n >= 5 -> 1.0
      n when n >= 3 -> 0.8
      2 -> 0.55
      _ -> 0.15
    end
  end

  @doc """
  Can they fund a key-money deal?

  **Review count means opposite things in the two populations.** A restaurant chain's
  reviews are its footfall, so they track its size. A B2B catering company's
  customers are corporations that never leave a Google review — "شركة أنوفا لخدمات
  الإعاشة" carries 50 reviews and may serve thousands of meals a day. Scoring both
  populations on review mass systematically deletes exactly the buyers most likely to
  want a production kitchen, so the kitchen track leans on legal form and sector
  instead.
  """
  @spec capacity(map(), map(), atom()) :: float()
  def capacity(row, norms, track \\ :a) do
    rv = :math.log10((row[:total_reviews] || 0) + 1) / max(norms.max_log_rev, 1.0)
    br = min(1.0, (row[:branches] || 0) / 12.0)
    site = if row[:website] not in [nil, ""], do: 1.0, else: 0.0
    ent = entity(row)

    case track do
      :a2 -> clamp(0.45 * ent + 0.20 * b2b_sector(row) + 0.15 * br + 0.12 * site + 0.08 * rv)
      _ -> clamp(0.40 * rv + 0.25 * br + 0.20 * ent + 0.15 * site)
    end
  end

  # Categories that trade with businesses rather than walk-in customers.
  defp b2b_sector(row) do
    hay = hay(row)

    if Regex.match?(
         ~r/إعاشة|اعاشة|تموين|توريد|متعهد|تصنيع|مورد|كاترينج|catering|مطبخ مركزي|ضيافة/u,
         hay
       ),
       do: 1.0,
       else: 0.0
  end

  @doc """
  Can this target be reached today, and through a channel that actually gets answered?
  """
  @spec reach(map()) :: float()
  def reach(row) do
    wa = Contact.wa_link(row[:phone]) != nil
    email = row[:emails] not in [nil, []]
    ig = Contact.instagram_handle(row[:website]) != nil
    site = Contact.real_website(row[:website]) != nil
    phone = row[:phone] not in [nil, ""]

    base =
      cond do
        wa -> 1.0
        ig -> 0.65
        email -> 0.55
        phone -> 0.45
        site -> 0.3
        true -> 0.1
      end

    # A second independent channel is worth real probability on a short deadline.
    extras = Enum.count([wa, email, ig, site], & &1)
    clamp(base + (extras - 1) * 0.05)
  end

  # Decision latency as a probability multiplier, not a label.
  defp speed_factor(row, track) do
    case GmapsEx.Malqa.Score.speed(row, track) do
      {:fast, _} -> 1.0
      {:medium, _} -> 0.55
      {:slow, _} -> 0.2
    end
  end

  @doc """
  قوة الفرصة — the size of the prize, ignoring whether it can be caught.

  Weights differ by track because the tracks are hunting different things: the
  kitchen track is sold on the kitchen, the white-space track on the gap, the Egypt
  track on demand for a cuisine that is missing here.
  """
  @spec strength(vars(), atom()) :: non_neg_integer()
  def strength(v, track) do
    w = weights(track)

    raw =
      w.pull * v.pull +
        w.asset * v.asset_fit +
        w.momentum * v.momentum +
        w.gap * v.gap +
        w.twin * v.twin +
        w.quality * v.quality +
        w.capacity * v.capacity +
        w.proven * v.proven

    round(clamp(raw) * 100)
  end

  # A: the deal is the gap in their map, so pull and gap lead.
  defp weights(:a),
    do: %{pull: 0.22, asset: 0.12, momentum: 0.12, gap: 0.15, twin: 0.11, quality: 0.09, capacity: 0.09, proven: 0.10}

  # A2: they are buying the kitchen, but the binding question is whether they can
  # actually fund it — so solvency and a proven second opening outweigh concept fit.
  defp weights(:a2),
    do: %{pull: 0.05, asset: 0.20, momentum: 0.05, gap: 0.02, twin: 0.04, quality: 0.12, capacity: 0.32, proven: 0.20}

  # B: cuisine demand at this address dominates; a missing cuisine is the whole case.
  defp weights(:b),
    do: %{pull: 0.30, asset: 0.16, momentum: 0.05, gap: 0.05, twin: 0.03, quality: 0.14, capacity: 0.17, proven: 0.10}

  # KSA-outside-Riyadh: the case is a proven Saudi format plus an empty capital, so
  # quality and capacity carry it — there is no "gap from the site" to measure when
  # the brand has no Riyadh branches at all.
  defp weights(:ksa),
    do: %{pull: 0.24, asset: 0.16, momentum: 0.10, gap: 0.02, twin: 0.02, quality: 0.18, capacity: 0.18, proven: 0.10}

  defp weights(_), do: weights(:a)

  @doc "احتمال الإغلاق داخل المهلة — reachability times decision latency."
  @spec close_probability(vars()) :: float()
  def close_probability(v), do: Float.round(clamp(v.reach * v.speed), 3)

  @doc """
  The multiplier actually used for ranking.

  Ranking on the raw product collapsed the shortlist: every surviving row scored
  exactly 1.00, so probability ordered nothing and strong-but-slower targets were
  deleted rather than demoted. A floor keeps them on the sheet — ranked below the
  reachable ones, which is the honest treatment of a brand worth pursuing that simply
  will not sign this month.
  """
  @spec rank_multiplier(vars()) :: float()
  def rank_multiplier(v), do: 0.35 + 0.65 * close_probability(v)

  @doc """
  الترتيب النهائي — expected value: strength × probability.

  This is why a reachable good brand outranks an unreachable excellent one. On an
  eighteen-day clock, a deal you cannot start is worth nothing.
  """
  @spec rank_score(vars(), atom()) :: non_neg_integer()
  def rank_score(v, track), do: round(strength(v, track) * rank_multiplier(v))

  @doc "One line of Arabic explaining what drove this candidate's position."
  @spec explain_ar(vars(), map(), atom(), map()) :: String.t()
  def explain_ar(v, row, track, cat_stats) do
    cat = row[:top_category]
    st = Map.get(cat_stats, cat, %{reviews_per_outlet: 0.0, near_1km: 0, outlets: 0})

    [
      if(st.reviews_per_outlet > 600,
        do: "طلب مرتفع على #{cat}: #{round(st.reviews_per_outlet)} تقييم لكل فرع",
        else: nil
      ),
      if(st.near_1km == 0, do: "لا يوجد منافس بنفس الفئة خلال كم", else: "#{st.near_1km} منافس خلال كم"),
      if(v.kitchen_fit >= 0.9, do: "المفهوم يعتمد على مطبخ إنتاج — الأصل الأثمن عندك", else: nil),
      if(track != :a2 and (row[:d_min] || 0) > 3,
        do: "أقرب فرع لهم #{Float.round((row[:d_min] || 0) / 1, 1)} كم",
        else: nil
      ),
      if(v.momentum >= 0.8, do: "توسّع نشط — فروع حديثة", else: nil),
      if(v.twin >= 0.6, do: "#{round(v.twin * 100)}٪ من فروعهم في أحياء تشبه الملقا", else: nil),
      if(v.entity >= 1.0, do: "كيان تجاري مسجّل", else: nil),
      if(v.proven >= 0.8, do: "#{row[:branches]} مواقع — أثبتوا قدرتهم على الافتتاح", else: nil),
      if(v.speed >= 1.0, do: "قرار سريع", else: nil),
      if(v.reach >= 0.95, do: "واتساب مباشر", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.take(5)
    |> Enum.join(" · ")
  end

  @doc "Population maxima used to scale the unbounded variables."
  @spec norms([map()], map()) :: map()
  def norms(rows, cat_stats) do
    rpos =
      cat_stats
      |> Map.values()
      |> Enum.filter(&(&1.outlets >= 4))
      |> Enum.map(& &1.reviews_per_outlet)

    %{
      max_rpo: percentile(rpos, 0.95),
      max_log_rev:
        rows
        |> Enum.map(&:math.log10((&1[:total_reviews] || 0) + 1))
        |> percentile(0.95)
    }
  end

  # The 95th percentile, not the maximum: one runaway outlier would flatten every
  # other candidate to near zero.
  defp percentile([], _), do: 1.0

  defp percentile(list, p) do
    sorted = Enum.sort(list)
    idx = min(length(sorted) - 1, trunc(length(sorted) * p))
    max(Enum.at(sorted, idx), 1.0)
  end

  @doc """
  The searchable text for a brand: category, name and every member branch title.

  Built once per row and cached under `:_hay`, because five different predicates
  (`kitchen_fit`, `hall_fit`, `entity`, `b2b_sector`, `track_a2`) each need it. A
  48-branch brand's titles are a long string, and rebuilding it per predicate for
  every candidate on every track turned scoring from seconds into minutes.
  """
  @spec hay(map()) :: String.t()
  def hay(%{_hay: cached}) when is_binary(cached), do: cached

  def hay(row) do
    [row[:top_category], row[:brand_name], Enum.join(List.wrap(row[:member_titles]), " ")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  @doc "Attach the cached `:_hay` text to a row before scoring it repeatedly."
  @spec with_hay(map()) :: map()
  def with_hay(row), do: Map.put(row, :_hay, hay(Map.delete(row, :_hay)))

  defp clamp(v) when is_number(v), do: v |> max(0.0) |> min(1.0)
  defp clamp(_), do: 0.0

  @doc false
  def district_label(tag), do: Districts.tag_for_name(tag) || tag
end
