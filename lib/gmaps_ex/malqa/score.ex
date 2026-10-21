defmodule GmapsEx.Malqa.Score do
  @moduledoc """
  Scoring for the three target tracks.

  Pure functions over the aggregated brand rows from `GmapsEx.Whitespace.brands/1`,
  in the style the rest of this repo already uses: sub-scores summed to 0–100, then
  `grade/1` cut points. Nothing here touches the network, so weights can be re-tuned
  and the whole list re-ranked in seconds.

  Every weight lives in `@weights` so `--weights file.json` can override it without
  a recompile — which is what makes the ablation check in the verification pass
  cheap enough to actually run.
  """

  alias GmapsEx.Malqa.{Contact, Districts}

  @weights %{
    new_branch_reviews: 60,
    gap_min_km: 2.5,
    a_quality: 20,
    a_scale: 15,
    a_chain: 20,
    a_momentum: 15,
    a_twin: 15,
    a_gap: 10,
    a_catspace: 5,
    a_contact: 5
  }

  @spec weights() :: map()
  def weights, do: @weights

  # The F&B query set still drags in neighbours — a florist beside a cafe, a car
  # wash on the same strip. Track A is about restaurant brands, so the category has
  # to actually be food.
  @fnb_category ~w(
    مطعم مطاعم كافيه كافيهات مقهى مقاهي قهوة مخبز مخبوزات حلويات حلوى بوظة آيس
    عصير عصائر شاورما برجر بيتزا معجنات فطائر فطير كشري مشويات دجاج بوفيه
    مأكولات طعام شيكولاتة شوكولا كعك دونات وجبات مشروبات
    restaurant cafe coffee bakery dessert sweet juice burger pizza grill
    shawarma chicken breakfast brunch food bar tea donut ice
  )

  @doc "Is this brand actually in food & beverage?"
  @spec fnb?(map()) :: boolean()
  def fnb?(row) do
    hay =
      [row[:top_category], row[:brand_name]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(@fnb_category, &String.contains?(hay, &1))
  end

  # ── Track A: Riyadh chains missing from the site's catchment ───────────

  @doc """
  Score a brand as a white-space target.

  Hard gates to zero: a branch already inside the catchment (it is by definition not
  white space), or fewer than two branches (not a chain — there is no expansion
  decision to make).
  """
  @spec track_a(map(), map()) :: non_neg_integer()
  def track_a(row, ctx \\ %{}) do
    w = Map.merge(@weights, Map.get(ctx, :weights, %{}))

    cond do
      (row[:within_3km] || 0) > 0 -> 0
      (row[:branches] || 0) < 2 -> 0
      not fnb?(row) -> 0
      true -> do_track_a(row, ctx, w)
    end
  end

  defp do_track_a(row, ctx, w) do
    n = row[:branches] || 0

    quality = band(row[:w_rating], 3.2, 4.5, w.a_quality)
    scale = min(w.a_scale, round(4.0 * :math.log10((row[:total_reviews] || 0) + 1)))

    chain =
      cond do
        n >= 7 and n <= 15 -> w.a_chain
        n >= 3 and n <= 6 -> round(w.a_chain * 0.8)
        n >= 16 and n <= 25 -> round(w.a_chain * 0.75)
        n >= 26 and n <= 40 -> round(w.a_chain * 0.45)
        n > 40 -> round(w.a_chain * 0.15)
        true -> round(w.a_chain * 0.3)
      end

    # A 2-branch brand with one new branch reads as 50% "momentum" on pure noise,
    # so the term only applies once there are enough branches for the ratio to mean
    # something.
    momentum =
      if n < 3,
        do: 0,
        else: round(min(1.0, (row[:new_branch_frac] || 0.0) / 0.35) * w.a_momentum)

    twin = round((row[:twin_frac] || 0.0) * w.a_twin)

    gap =
      case row[:d_min] do
        nil -> 0
        d when d < 1.5 -> 0
        d when d < 3.0 -> round(w.a_gap * 0.3)
        d when d < 6.0 -> round(w.a_gap * 0.7)
        d when d < 12.0 -> w.a_gap
        _ -> round(w.a_gap * 0.8)
      end

    catspace = category_space(row, ctx, w.a_catspace)
    contact = contact_points(row, w.a_contact)

    min(100, quality + scale + chain + momentum + twin + gap + catspace + contact)
  end

  # How crowded is this brand's own category right next to the site? A concept with
  # four lookalikes within 1 km is a hard sell regardless of how good the brand is.
  defp category_space(row, ctx, max_pts) do
    density = Map.get(ctx, :category_density, %{})
    cat = row[:top_category]
    n = Map.get(density, cat, 0)
    max(0, max_pts - n)
  end

  # ── Track A2: buyers of the kitchen, not the dining room ───────────────

  @kitchen_fit [
    {~w(مطبخ مركزي central kitchen), 30},
    {~w(إعاشة اعاشة), 28},
    {~w(تموين), 26},
    {~w(كاترينج catering), 25},
    {~w(مطبخ سحابي cloud kitchen ghost kitchen), 24},
    {~w(ضيافة hospitality), 22},
    {~w(بوفيه ولائم buffet banquet), 20},
    {~w(قاعة أفراح قاعة افراح wedding hall), 18},
    {~w(حفلات تجهيز event), 16},
    {~w(مصنع حلويات مخبز إنتاج factory), 14},
    {~w(وجبات جاهزة meal prep), 14}
  ]

  # "ضيافة" means hospitality, but "ضيافة أطفال" is a daycare centre, and a kitchen
  # equipment trader is not a kitchen operator. Without these the track fills up
  # with nurseries and shops.
  @not_a_kitchen_buyer ~w(
    أطفال حضانة روضة رياض مدرسة تعليم
    معدات أدوات تجهيزات مستلزمات صيانة
    سوبرماركت بقالة تموينات هايبر متجر
    equipment supplies nursery daycare kindergarten school academy
    trading spare maintenance
  )

  @doc """
  Score a kitchen-led buyer.

  No gap term at all: a caterer will take a production kitchen anywhere in north
  Riyadh. Contactability is weighted higher here than in any other track, because
  this is the list that can close inside the month and the only thing that matters
  is reaching the owner today.
  """
  @spec track_a2(map(), map()) :: non_neg_integer()
  def track_a2(row, _ctx \\ %{}) do
    hay = GmapsEx.Malqa.Opportunity.hay(row)

    fit =
      Enum.find_value(@kitchen_fit, 6, fn {terms, pts} ->
        if Enum.any?(terms, &String.contains?(hay, &1)), do: pts
      end)

    registered = Regex.match?(~r/شركة|مؤسسة|company|est\b|co\./iu, hay)

    capacity =
      min(20, round(3.5 * :math.log10((row[:total_reviews] || 0) + 1))) +
        if(registered, do: 4, else: 0) +
        if(row[:website] not in [nil, ""], do: 3, else: 0)

    # Already in the affluent north = already served. Elsewhere = needs a north site.
    pull =
      cond do
        Districts.twin?(row[:nearest_district]) -> 6
        row[:nearest_district] in [nil, "other"] -> 8
        true -> 15
      end

    reputation = band(row[:w_rating], 3.0, 4.6, 15)
    contact = contact_points(row, 20)

    cat = String.downcase(to_string(row[:top_category] || ""))

    # A shop that sells kitchen equipment is not a buyer of a kitchen, however many
    # times the word "catering" appears in its name.
    retail = Regex.match?(~r/متجر|محل|معرض|store|shop|trading|supplies/iu, cat)
    equipment = Regex.match?(~r/معدات|أدوات|ادوات|تجهيزات|equipment|أثاث/iu, hay)

    cond do
      home_kitchen?(row) -> 0
      retail and equipment -> 0
      Enum.any?(@not_a_kitchen_buyer, &String.contains?(hay, &1)) and fit < 25 -> 0
      fit <= 6 -> 0
      true -> min(100, fit + min(20, capacity) + pull + reputation + contact)
    end
  end

  defp home_kitchen?(row) do
    row[:phone] in [nil, ""] and (row[:total_reviews] || 0) < 5 and row[:website] in [nil, ""]
  end

  # ── Track B: Egyptian brands, ranked by measured KSA commitment ────────

  # Cross-script trigram matching cannot connect "Starbucks" in Cairo to "ستاربكس"
  # in Riyadh — the strings share no characters — so global chains survive the
  # fuzzy KSA check and look like brands that still need a Saudi site. They do not.
  # A short explicit list terminates where the heuristic cannot.
  @already_global ~w(
    starbucks mcdonald kfc "papa john" pizzahut "pizza hut" "burger king" hardee
    subway dunkin "costa coffee" costa "cold stone" "baskin" "krispy kreme"
    "tim hortons" "second cup" cinnabon "auntie anne" "caribou" "dominos"
    "domino's" "texas chicken" "chili's" "applebee" "tgi" "shake shack" "five guys"
    "pinkberry" "cinnzeo" "herfy" "albaik" nando "wendy" popeyes "little caesars"
    بابا_جونز ستاربكس كوستا دانكن سينابون ماكدونالدز هارديز صب_واي
  )

  @doc """
  Score an Egyptian brand as a Riyadh entrant.

  `ksa_branches` is measured, not guessed — it comes from searching the brand name
  inside KSA on Maps. One to three branches is the hottest signal in the whole
  exercise: appetite proved, rollout underway, site hunt live.
  """
  @spec track_b(map(), map()) :: non_neg_integer()
  def track_b(row, ctx \\ %{}) do
    eg = row[:branches] || 0
    ksa = Map.get(ctx, :ksa_branches, row[:ksa_branches]) || 0
    signal = Map.get(ctx, :franchise_signal, row[:franchise_signal]) || false
    franex = Map.get(ctx, :franex, row[:franex]) || false
    space_fit = Map.get(ctx, :space_fit, row[:space_fit]) || false

    name = row[:brand_name] |> to_string() |> String.downcase()

    reviews = row[:total_reviews] || 0

    riyadh = Map.get(ctx, :riyadh_branches, row[:riyadh_branches]) || 0

    cond do
      # Branch counts out of a zonal harvest are a lower bound, not a fact: حجوجة
      # shows one branch here and carries 34,746 reviews. Review mass is the more
      # honest proxy for whether a brand is big enough to fund a Riyadh entry, so a
      # single heavyweight listing qualifies even when its siblings were not sampled.
      eg < 3 and reviews < 5_000 -> 0
      not fnb?(row) -> 0
      # The whole proposition is a Riyadh site. A brand already trading in Riyadh
      # does not need one.
      riyadh > 0 -> 0
      # A three-branch brand with 40 reviews between them is not a chain that can
      # fund a Riyadh entry.
      reviews < 500 -> 0
      Enum.any?(@already_global, &String.contains?(name, String.replace(&1, "_", " "))) -> 0
      true -> do_track_b(row, eg, ksa, signal, franex, space_fit)
    end
  end

  defp do_track_b(row, eg, ksa, signal, franex, space_fit) do
    tier =
      cond do
        ksa >= 1 and ksa <= 3 -> 40
        signal -> 28
        ksa >= 4 and ksa <= 10 -> 22
        ksa > 10 -> 4
        true -> 8
      end

    scale =
      cond do
        eg >= 5 and eg <= 40 -> 20
        eg >= 3 -> 14
        # Under-sampled heavyweight: scored on review mass instead of branch count.
        (row[:total_reviews] || 0) >= 20_000 -> 18
        (row[:total_reviews] || 0) >= 5_000 -> 13
        eg <= 80 -> 12
        true -> 6
      end

    quality = band(row[:w_rating], 3.2, 4.6, 15)
    evidence = min(15, if(franex, do: 10, else: 0) + if(space_fit, do: 5, else: 0))
    expansion = if signal, do: 10, else: 0
    contact = contact_points(row, 10)

    min(100, tier + scale + quality + evidence + expansion + contact)
  end

  @doc """
  How fast can this target actually sign?

  The deadline is eighteen days, so this matters more than fit. A global brand
  operating in Riyadh through a master franchisee has a real-estate committee;
  an owner-operator with six branches answers his own WhatsApp. Branch count alone
  does not separate them — Tim Hortons shows seven Riyadh branches and is still a
  corporate decision — so brand origin and review mass carry the signal.
  """
  @spec speed(map(), atom()) :: {:fast | :medium | :slow, String.t()}
  def speed(row, track) do
    name = to_string(row[:brand_name] || "")
    latin = Regex.match?(~r/^[A-Za-z0-9&'.\- ]{4,}$/u, String.trim(name))
    reviews = row[:total_reviews] || 0
    n = row[:branches] || 0
    reachable = Contact.wa_link(row[:phone]) != nil

    cond do
      track == :a2 and reachable -> {:fast, "مشغّل محلي — قرار في أيام"}
      latin and reviews > 20_000 -> {:slow, "براند عالمي بمشغّل رئيسي — لجنة عقارية"}
      n > 25 -> {:slow, "سلسلة كبيرة — دورة موافقات طويلة"}
      latin and n >= 5 -> {:slow, "براند أجنبي — الموافقة من خارج السعودية غالباً"}
      reachable and n <= 15 -> {:fast, "مالك/مشغّل يرد بنفسه — قرار سريع"}
      n <= 15 -> {:medium, "سلسلة متوسطة — أسبوعان إلى شهر"}
      true -> {:medium, "دورة قرار متوسطة"}
    end
  end

  @doc """
  Grade by position within the track, not against absolute cut points.

  Fixed cut points graded 30% of Track A as A+ and 100% of Track A2 as A or better,
  which ranks nothing. Percentiles self-calibrate as the dataset grows.
  """
  @spec grade_by_rank(non_neg_integer(), non_neg_integer()) :: String.t()
  def grade_by_rank(_index, 0), do: "C"

  def grade_by_rank(index, total) do
    p = index / total

    cond do
      p <= 0.10 -> "A+"
      p <= 0.30 -> "A"
      p <= 0.65 -> "B"
      true -> "C"
    end
  end

  @doc """
  Score a brand that is strong elsewhere in Saudi Arabia but absent from Riyadh.

  This is the segment a Riyadh site is worth most to: the format is proven on Saudi
  customers, the operator is domestic (so no cross-border approval, no master
  franchisee, no committee abroad), and the capital's absence from their map is the
  gap they are already thinking about. Any Riyadh presence at all disqualifies —
  the entire proposition is that they are not here yet.
  """
  @spec track_ksa(map(), map()) :: non_neg_integer()
  def track_ksa(row, ctx \\ %{}) do
    riyadh = Map.get(ctx, :riyadh_branches, row[:riyadh_branches]) || 0
    n = row[:branches] || 0
    reviews = row[:total_reviews] || 0

    cond do
      riyadh > 0 -> 0
      n < 2 -> 0
      not fnb?(row) -> 0
      reviews < 400 -> 0
      true -> do_track_ksa(row, n, reviews)
    end
  end

  defp do_track_ksa(row, n, reviews) do
    # Proven at home: enough branches to show the format travels, not so many that a
    # property department already owns the decision.
    scale =
      cond do
        n >= 4 and n <= 25 -> 28
        n >= 2 -> 20
        n <= 45 -> 14
        true -> 6
      end

    quality = band(row[:w_rating], 3.3, 4.6, 22)
    mass = min(18, round(5.0 * :math.log10(reviews + 1)))

    momentum =
      if n < 3, do: 4, else: round(min(1.0, (row[:new_branch_frac] || 0.0) / 0.35) * 14)

    contact = contact_points(row, 18)

    min(100, scale + quality + mass + momentum + contact)
  end

  # ── shared ────────────────────────────────────────────────────────────

  defp contact_points(row, max_pts) do
    email = row[:emails] not in [nil, []]
    ig = Contact.instagram_handle(row[:website]) != nil
    mobile = Contact.wa_link(row[:phone]) != nil
    site = Contact.real_website(row[:website]) != nil

    cond do
      email -> max_pts
      ig -> round(max_pts * 0.8)
      mobile -> round(max_pts * 0.6)
      site -> round(max_pts * 0.4)
      row[:phone] not in [nil, ""] -> round(max_pts * 0.3)
      true -> 0
    end
  end

  defp band(nil, _lo, _hi, _max), do: 0

  defp band(v, lo, hi, max_pts) do
    v = v / 1
    cond do
      v <= lo -> 0
      v >= hi -> max_pts
      true -> round((v - lo) / (hi - lo) * max_pts)
    end
  end

  @doc """
  Grade cut points.

  Provisional until the real decile distribution is known — if more than ~20% of a
  track lands A+, the cut points are wrong, not the weights.
  """
  @spec grade(number()) :: String.t()
  def grade(score) when score >= 72, do: "A+"
  def grade(score) when score >= 60, do: "A"
  def grade(score) when score >= 46, do: "B"
  def grade(_), do: "C"

  @doc "One line of Arabic evidence for why this brand is on the list."
  @spec why_ar(map(), atom()) :: String.t()
  def why_ar(row, track) do
    n = row[:branches] || 0
    rating = row[:w_rating] && Float.round(row[:w_rating] / 1, 1)
    d = row[:d_min] && Float.round(row[:d_min] / 1, 1)
    twin = round((row[:twin_frac] || 0) * 100)
    fresh = round((row[:new_branch_frac] || 0) * 100)

    base =
      case track do
        :a2 ->
          ["#{n} موقع", rating && "تقييم #{rating}", row[:top_category]]

        :b ->
          [
            "#{n} فرع في مصر",
            rating && "تقييم #{rating}",
            row[:ksa_branches] && "#{row[:ksa_branches]} فرع في السعودية"
          ]

        _ ->
          [
            "#{n} فرع بالرياض",
            rating && "تقييم #{rating}",
            d && "أقرب فرع #{d} كم",
            twin > 0 && "#{twin}٪ من فروعهم في أحياء مشابهة للملقا",
            fresh > 0 && "#{fresh}٪ فروع حديثة"
          ]
      end

    base
    |> Enum.reject(&(&1 in [nil, false, ""]))
    |> Enum.join(" · ")
  end
end
