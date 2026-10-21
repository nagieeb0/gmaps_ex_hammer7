defmodule Mix.Tasks.Gmaps.KsaEmployers do
  @moduledoc """
  Employer sweep for a senior O&M / facilities engineer job search in KSA —
  every company in Jeddah, Riyadh, Makkah and the Eastern Province that plausibly
  hires a **Maintenance & Operations Director**, ranked by how reachable and how
  good a fit they are.

      mix gmaps.ksa_employers                       # full sweep → jobs/
      mix gmaps.ksa_employers --dry-run             # job count only
      mix gmaps.ksa_employers --cities jeddah       # Jeddah only (highest priority)
      mix gmaps.ksa_employers --sectors fm,om,hvac

  Output lands in `jobs/`:
    * `shortlist.csv`            — core-relevance + reachable. Start here.
    * `contactable.csv`          — any row with an email or a website
    * `ksa-employers.csv`        — everything, ranked
    * `by-city/<city>.csv`       — split per city
    * `by-sector/<sector>.csv`   — split per scrape sector

  The DB accumulates (upsert by place id), so partial/split runs are additive.
  Re-rank without re-scraping: `mix gmaps.ksa_employers --export-only`.

  ## Fit score (0–100)

  Ranked on *can he actually apply, and would they hire his profile* — not on
  how nice the company is:

    * sector fit   (≤30) — FM / O&M contractors first, then MEP + HVAC, then
                           hospitals (they staff maintenance in-house), then
                           industrial and recruiters. Scaled by `relevance/1`,
                           see below.
    * reachable    (≤30) — email 30 · website 18 · phone only 10. An email is
                           worth double a phone: a CV goes out today.
    * size proxy   (≤20) — review_count log-scaled. Big enough to have a
                           director layer at all.
    * city         (≤10) — Jeddah 10 (he lives there) · Riyadh 7 · Makkah 4 ·
                           Eastern Province 4
    * reputation   (≤10) — review_rating, only once there are ≥5 reviews

  Permanently-closed places, and `reject`-relevance categories, score 0.

  Grades: A+ ≥75 · A ≥62 · B ≥48 · C below.

  ## Relevance

  The sector tag records which *query* found a place, not what the place *is* —
  "شركة صيانة" returns car workshops next to real O&M contractors. So sector fit
  is multiplied by how well the Google category corroborates it:

    * `core`       ×1.0  — construction, HVAC contractor, hospital, factory,
                           refinery, water plant, property maintenance, recruiter
    * `unverified` ×0.5  — blank or unrecognised category; not judged either way
    * `weak`       ×0.2  — sells the trade rather than practising it (suppliers,
                           stores), plus small clinics and generic consultants
    * `reject`     →0    — consumer trades and retail: car and appliance repair,
                           restaurants, shops, mosques, nurseries, one-man trades

  Reachability is never discounted — a weak-tier place with a real email still
  beats a core-tier place with no contact at all. The tier is written to the
  `relevance` CSV column, so a bad call is visible and fixable rather than
  silently dropped.
  """

  use Mix.Task

  @shortdoc "Scrape KSA FM/O&M/HVAC/hospital employers ranked for a senior maintenance-director job hunt"

  @out_dir "jobs"

  # ── Queries: {sector, query} ──────────────────────────────────────────
  # Arabic first for each concept — Google Maps KSA indexes the Arabic trade
  # name far more completely than the English one for local contractors.
  @queries [
    # ── fm: إدارة المرافق ──
    {"fm", "إدارة المرافق"},
    {"fm", "facility management"},
    {"fm", "شركة إدارة مرافق"},
    {"fm", "facility management company"},
    {"fm", "خدمات المرافق المتكاملة"},
    {"fm", "integrated facility services"},
    {"fm", "خدمات مساندة"},
    {"fm", "support services company"},
    {"fm", "نظافة وصيانة مباني"},
    {"fm", "building maintenance"},

    # ── om: تشغيل وصيانة ──
    {"om", "تشغيل وصيانة"},
    {"om", "operation and maintenance"},
    {"om", "شركة صيانة"},
    {"om", "maintenance company"},
    {"om", "صيانة وتشغيل مستشفيات"},
    {"om", "hospital maintenance services"},
    {"om", "عقود الصيانة"},
    {"om", "maintenance contractor"},
    {"om", "صيانة منشآت"},
    {"om", "plant maintenance services"},

    # ── hvac: تكييف وتبريد ──
    {"hvac", "تكييف مركزي"},
    {"hvac", "central air conditioning company"},
    {"hvac", "شركة تكييف وتبريد"},
    {"hvac", "hvac company"},
    {"hvac", "صيانة تكييف مركزي"},
    {"hvac", "hvac contractor"},
    {"hvac", "تبريد مركزي"},
    {"hvac", "district cooling"},
    {"hvac", "وحدات مناولة هواء"},
    {"hvac", "chiller maintenance"},

    # ── mep: كهروميكانيك ──
    {"mep", "مقاولات كهروميكانيكية"},
    {"mep", "mep contractor"},
    {"mep", "أعمال كهروميكانيكية"},
    {"mep", "electromechanical company"},
    {"mep", "أنظمة ميكانيكية"},
    {"mep", "mechanical engineering company"},
    {"mep", "مكافحة حريق وأنظمة إطفاء"},
    {"mep", "fire fighting systems company"},

    # ── contracting: مقاولات وإنشاءات ──
    {"contracting", "شركة مقاولات"},
    {"contracting", "contracting company"},
    {"contracting", "مقاولات عامة"},
    {"contracting", "general contractor"},
    {"contracting", "شركة إنشاءات"},
    {"contracting", "construction company"},
    {"contracting", "مقاولات بنية تحتية"},
    {"contracting", "infrastructure contractor"},

    # ── hospital: يوظفون مدير صيانة داخلي ──
    {"hospital", "مستشفى"},
    {"hospital", "hospital"},
    {"hospital", "مستشفى خاص"},
    {"hospital", "private hospital"},
    {"hospital", "مدينة طبية"},
    {"hospital", "medical city"},
    {"hospital", "مجمع طبي"},
    {"hospital", "medical complex"},

    # ── industrial: نفط ومياه وصناعة ──
    {"industrial", "مصفاة"},
    {"industrial", "refinery"},
    {"industrial", "شركة خدمات بترولية"},
    {"industrial", "oilfield services company"},
    {"industrial", "محطة تحلية مياه"},
    {"industrial", "water desalination company"},
    {"industrial", "محطة معالجة مياه صرف صحي"},
    {"industrial", "wastewater treatment company"},
    {"industrial", "مصنع"},
    {"industrial", "industrial company"},

    # ── recruitment: مكاتب التوظيف ──
    {"recruitment", "مكتب توظيف"},
    {"recruitment", "recruitment agency"},
    {"recruitment", "شركة استقدام"},
    {"recruitment", "manpower company"},
    {"recruitment", "استشارات موارد بشرية"},
    {"recruitment", "hr consultancy"},
    {"recruitment", "executive search"}
  ]

  # ── Zones: {city, tag, lat, lon, half_w_km, half_h_km, cell_km} ───────
  @zones [
    # Jeddah — where he lives, highest priority
    {"jeddah", "north-obhur", 21.72, 39.11, 6.0, 8.0, 4.0},
    {"jeddah", "north", 21.63, 39.16, 6.0, 6.0, 4.0},
    {"jeddah", "central", 21.54, 39.19, 6.0, 6.0, 4.0},
    {"jeddah", "east", 21.55, 39.28, 6.0, 6.0, 4.0},
    {"jeddah", "south", 21.42, 39.20, 6.0, 6.0, 4.0},
    {"jeddah", "industrial", 21.40, 39.24, 5.0, 5.0, 4.0},

    # Riyadh
    {"riyadh", "north", 24.79, 46.65, 8.0, 6.0, 4.0},
    {"riyadh", "central", 24.69, 46.70, 6.0, 6.0, 4.0},
    {"riyadh", "east", 24.72, 46.81, 6.0, 5.0, 4.0},
    {"riyadh", "west", 24.65, 46.57, 6.0, 5.0, 4.0},
    {"riyadh", "industrial", 24.52, 46.88, 5.0, 5.0, 4.0},

    # Makkah — commuting distance from Jeddah
    {"makkah", "central", 21.42, 39.83, 6.0, 6.0, 4.0},

    # Eastern Province — his refinery / water-plant background
    {"eastern", "dammam-khobar", 26.35, 50.13, 8.0, 8.0, 5.0},
    {"eastern", "jubail", 27.01, 49.66, 6.0, 6.0, 5.0},
    {"eastern", "qatif", 26.56, 50.01, 5.0, 5.0, 5.0},

    # Yanbu — refineries, Red Sea side
    {"yanbu", "industrial", 24.09, 38.06, 6.0, 6.0, 5.0}
  ]

  # Sector fit (≤30). FM/O&M contractors are the direct replacement for
  # Bin Laden / Zahran; recruiters score lowest because they are a channel,
  # not an employer — but they still belong in the list.
  @sector_fit %{
    "fm" => 30,
    "om" => 30,
    "hvac" => 26,
    "mep" => 24,
    "hospital" => 20,
    "contracting" => 18,
    "industrial" => 16,
    "recruitment" => 12
  }

  @city_fit %{"jeddah" => 10, "riyadh" => 7, "makkah" => 4, "eastern" => 4, "yanbu" => 3}

  # ── Relevance ─────────────────────────────────────────────────────────
  #
  # The sector tag says which QUERY found a place, not what the place IS.
  # "شركة صيانة" (maintenance company) returns car-repair workshops and
  # home-AC callout services alongside real O&M contractors, and they all
  # inherited the full 30-point om fit — the first run put a car workshop and
  # a plant nursery at the top of the A+ list.
  #
  # So sector fit is scaled by what Google actually categorised the place as.
  # Checked in order: reject → core → weak → unverified.
  @relevance_weight %{"core" => 1.0, "unverified" => 0.5, "weak" => 0.2}

  # Consumer-facing trades, retail, and one-man services. These have premises
  # and they do "maintenance", but they do not staff a director of it.
  @reject_kw [
    "تصليح سيارات",
    "ورشة إصلاح سيارات",
    "مركز صيانة سيارات",
    "ورشة ميكانيكا سيارات",
    "auto repair",
    "car repair",
    "خدمة تغيير الزيت",
    "oil change",
    "car wash",
    "مغسلة سيارات",
    "appliance repair",
    "خدمة إصلاح أجهزة",
    "ورشة إصلاح إلكترونيات",
    "ورشة إصلاح كهربائية",
    "electronics repair",
    "phone repair",
    "متجر إصلاح هواتف",
    "computer repair",
    "خدمة إصلاح أجهزة كمبيوتر",
    "computer support",
    "electric motor repair",
    "restaurant",
    "cafe",
    "coffee",
    "bakery",
    "مطعم",
    "مقهى",
    "كافيه",
    "مخبز",
    "ملحمة",
    "mosque",
    "مسجد",
    "school",
    "مدرسة",
    "روضة",
    "حضانة",
    "salon",
    "barber",
    "صالون",
    "حلاق",
    "hotel",
    "فندق",
    "atm",
    "صراف",
    "gas station",
    "محطة وقود",
    "parking",
    "موقف سيارات",
    "gym",
    "نادي رياضي",
    "pharmacy",
    "صيدلية",
    "laundry",
    "مغسلة",
    "supermarket",
    "سوبرماركت",
    "grocery",
    "بقالة",
    "مركز تسوق",
    "shopping mall",
    "plant nursery",
    "مشتل",
    # "plant" is a core keyword (industrial plant); these are the horticultural
    # senses of the same word and have to be caught before it.
    "interior plant",
    "plant service",
    "نباتات",
    "swimming pool",
    "حمام سباحة",
    "veterinary",
    "بيطري",
    "المساعدة المنزلية",
    "خادمات المنازل",
    "house cleaning",
    "تنظيف منازل",
    "interior design",
    "مصمم داخلي",
    "landscape",
    "real estate agency",
    "وكالة عقارات",
    "apartment building",
    "housing society",
    "condominium",
    "مجمع سكني",
    "نجار",
    "carpenter",
    "حداد",
    "blacksmith",
    "plumber",
    "سباك",
    "electrician",
    "كهربائي",
    "ميكانيكي",
    "tailor",
    "خياط",
    "call center",
    "بيفاتيل"
  ]

  # Unmistakably an organisation that runs plant and staffs an engineering
  # department. Substring match against the Google category.
  @core_kw [
    "construction",
    "إنشاء",
    "مقاول",
    "contractor",
    "contracting",
    "بناء",
    "builder",
    "building firm",
    "civil engineering",
    "hvac",
    "تكييف",
    "تبريد",
    "heating",
    "air conditioning contractor",
    "خدمات تدفئة",
    "mechanical contractor",
    "مقاول أجهزة ميكانيكية",
    "mechanical engineer",
    "industrial engineer",
    "engineering consultant",
    "مهندس استشاري",
    "hospital",
    "مستشفى",
    "مركز طبي",
    "medical center",
    "medical city",
    "مدينة طبية",
    "factory",
    "مصنع",
    "manufacturer",
    "plant",
    "refinery",
    "مصفاة",
    "oil",
    "بترول",
    "نفط",
    "gas company",
    "chemical",
    "كيماويات",
    "desalination",
    "تحلية",
    "water treatment",
    "معالجة مياه",
    "sewage",
    "صرف صحي",
    "water utility",
    "مرافق مياه",
    "مرافق الكهرباء",
    "utility",
    "waste management",
    "إدارة النفايات",
    "property maintenance",
    "صيانة الممتلكات",
    "property management",
    "إدارة عقارات",
    "facility",
    "مرافق",
    "machine maintenance",
    "صيانة آلات",
    "خدمة صيانة",
    "maintenance service",
    "elevator",
    "مصاعد",
    "fire protection",
    "مكافحة حريق",
    "حماية من الحريق",
    "corporate office",
    "مكتب الشركات",
    "government office",
    "مكتب حكومي",
    "recruit",
    "توظيف",
    "employment agency",
    "temp agency",
    "executive search",
    "human resource",
    "الموارد البشرية",
    "استقدام",
    "manpower",
    "waterproofing",
    "عزل مائي",
    "steel",
    "صلب",
    "معادن",
    "metal workshop",
    "machine workshop",
    "automation",
    "electrical installation",
    "scaffolding",
    "demolition",
    "drilling",
    "occupational safety",
    "warehouse",
    "مستودع",
    "logistics",
    "لوجستية",
    "developer",
    "مطوّر عقارات",
    "cleaning service",
    "عمال نظافة",
    "cleaners",
    "air duct cleaning"
  ]

  # Sells the trade rather than practising it. Outranks @core_kw so that a
  # counter selling chillers is never mistaken for a company that runs them.
  @retail_kw [
    "supplier",
    "مورد",
    "مورّد",
    "store",
    "متجر",
    "shop",
    "محل",
    "wholesale",
    "تاجر جملة",
    "wholesaler",
    "supply store",
    "rental",
    "تأجير"
  ]

  # Real businesses, wrong shape: they sell to the employers rather than
  # being one. Kept in the list at heavy discount rather than dropped —
  # a supplier's HR sometimes does staff a service division.
  @weak_kw [
    "clinic",
    "عيادة",
    "مختبر",
    "laboratory",
    "مستوصف",
    "dental",
    "أسنان",
    "consultant",
    "استشاري",
    "association",
    "منظمة",
    "business center",
    "transportation",
    "النقل",
    "security service",
    "software",
    "technology"
  ]

  @switches [
    csv: :string,
    jsonl: :string,
    dry_run: :boolean,
    export_only: :boolean,
    timeout: :integer,
    search_concurrency: :integer,
    place_concurrency: :integer,
    email_concurrency: :integer,
    sectors: :string,
    cities: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    if opts[:export_only] do
      Mix.Task.run("app.start")
      export(opts)
    else
      queries = filter_queries(opts[:sectors])
      zones = filter_zones(opts[:cities])
      seeds = build_seeds(queries, zones)

      Mix.shell().info("""
      :: KSA Employer Sweep (job search) → #{@out_dir}/
      :: #{length(queries)} queries × #{length(zones)} zones = #{length(seeds)} seed jobs
      :: sectors: #{queries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")}
      :: cities:  #{zones |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")}
      """)

      if opts[:dry_run] do
        for {city, tag, _, _, hw, hh, cell} <- zones do
          cells = grid_count(hw, hh, cell)

          Mix.shell().info(
            "   #{city}/#{tag}: #{cells} cells × #{length(queries)} = #{cells * length(queries)} jobs"
          )
        end

        Mix.shell().info(":: total #{length(seeds)} seed jobs — dry-run, nothing enqueued")
        System.halt(0)
      end

      Mix.Task.run("app.start")

      sc = opts[:search_concurrency] || 10
      pc = opts[:place_concurrency] || 20
      ec = opts[:email_concurrency] || 20
      Oban.scale_queue(queue: :search, limit: sc)
      Oban.scale_queue(queue: :place, limit: pc)
      Oban.scale_queue(queue: :emails, limit: ec)
      Mix.shell().info(":: concurrency search=#{sc} place=#{pc} emails=#{ec}")

      {:ok, n} = GmapsEx.Runner.start(seeds)
      Mix.shell().info(":: enqueued #{n} jobs — DB accumulates, split runs are additive")

      attach_progress_logger()
      wait_for_completion(opts[:timeout] || 8 * 60 * 60)

      export(opts)
    end
  end

  # ── seeds ─────────────────────────────────────────────────────────────

  defp filter_queries(nil), do: @queries
  defp filter_queries(csv), do: pick(@queries, csv, &elem(&1, 0), "sector")

  defp filter_zones(nil), do: @zones
  defp filter_zones(csv), do: pick(@zones, csv, &elem(&1, 0), "city")

  defp pick(list, csv, keyfun, label) do
    wanted = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

    case Enum.filter(list, &MapSet.member?(wanted, keyfun.(&1))) do
      [] ->
        known = list |> Enum.map(keyfun) |> Enum.uniq() |> Enum.join(", ")
        Mix.raise("no #{label} matched #{inspect(csv)} — known #{label}s: #{known}")

      filtered ->
        filtered
    end
  end

  defp build_seeds(queries, zones) do
    for {city, tag, lat, lon, hw, hh, cell} <- zones,
        {lat_c, lon_c} <- grid(lat, lon, hw, hh, cell),
        {sector, query} <- queries do
      %{
        query: query,
        input_id: "ksa-employers:#{city}:#{tag}:#{sector}",
        lat: lat_c,
        lon: lon_c,
        zoom: 14,
        lang: if(String.match?(query, ~r/^[\x00-\x7F]+$/), do: "en", else: "ar"),
        gl: "sa",
        # The whole point: an email means the CV goes out the same day.
        extract_emails: true
      }
    end
  end

  defp grid(lat, lon, hw_km, hh_km, cell_km) do
    step_lat = cell_km / 110.574
    step_lon = cell_km / (111.320 * :math.cos(lat * :math.pi() / 180.0))
    half_lat = hh_km / 110.574
    half_lon = hw_km / (111.320 * :math.cos(lat * :math.pi() / 180.0))

    for la <- frange(lat - half_lat, lat + half_lat, step_lat),
        lo <- frange(lon - half_lon, lon + half_lon, step_lon),
        do: {la, lo}
  end

  defp grid_count(hw, hh, cell), do: (trunc(2 * hh / cell) + 1) * (trunc(2 * hw / cell) + 1)

  defp frange(start, stop, step) do
    Stream.unfold(start, fn v -> if v > stop, do: nil, else: {v, v + step} end) |> Enum.to_list()
  end

  # ── ranking ───────────────────────────────────────────────────────────

  @doc "City tag parsed back out of `input_id`."
  @spec city(GmapsEx.Place.t()) :: String.t()
  def city(%{input_id: "ksa-employers:" <> rest}) do
    case String.split(rest, ":") do
      [city | _] -> city
      _ -> "unknown"
    end
  end

  def city(_), do: "unknown"

  @doc "Sector tag parsed back out of `input_id`."
  @spec sector(GmapsEx.Place.t()) :: String.t()
  def sector(%{input_id: "ksa-employers:" <> rest}) do
    case String.split(rest, ":") do
      [_city, _zone, sector | _] -> sector
      _ -> "unknown"
    end
  end

  def sector(_), do: "unknown"

  @doc """
  How well the Google category backs up the query that found this place:
  `core` · `weak` · `unverified` · `reject`. Written to its own CSV column so a
  misjudged call is visible and correctable instead of silently deleting a row.
  """
  @spec relevance(GmapsEx.Place.t()) :: String.t()
  def relevance(p) do
    hay =
      [p.category | p.categories || []]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      hay == "" -> "unverified"
      String.contains?(hay, @reject_kw) -> "reject"
      # Retail is checked BEFORE core: "متجر تكييف الهواء" is an air-conditioning
      # *shop*, and the trade word would otherwise promote it to core.
      String.contains?(hay, @retail_kw) -> "weak"
      String.contains?(hay, @core_kw) -> "core"
      String.contains?(hay, @weak_kw) -> "weak"
      true -> "unverified"
    end
  end

  @doc """
  Fit score 0–100. Closed places and rejected categories short-circuit to 0 so
  they sink below every real lead instead of being dropped.
  """
  @spec score(GmapsEx.Place.t()) :: non_neg_integer()
  def score(p) do
    rel = relevance(p)

    if closed?(p) or rel == "reject" do
      0
    else
      # Only the sector fit is discounted — a weakly-matched place with a real
      # email in Jeddah is still worth a CV, it just should not outrank a
      # genuine FM contractor.
      fit = Map.get(@sector_fit, sector(p), 10) * Map.fetch!(@relevance_weight, rel)

      round(fit) +
        Enum.sum([
          reach_points(p),
          size_points(p.review_count || 0),
          Map.get(@city_fit, city(p), 0),
          reputation_points(p)
        ])
    end
  end

  defp reach_points(p) do
    cond do
      (p.emails || []) != [] -> 30
      not blank?(p.website) -> 18
      not blank?(p.phone) -> 10
      true -> 0
    end
  end

  # log-scaled: 10 reviews ≈ 7 pts, 100 ≈ 13, 1000 ≈ 20. A director-level org
  # is rarely a 3-review place, but reviews are a weak proxy so the ceiling is low.
  defp size_points(0), do: 0
  defp size_points(n), do: min(20, round(:math.log10(n + 1) * 6.7))

  defp reputation_points(%{review_rating: r, review_count: c}) when is_number(r) and c >= 5,
    do: round(max(r - 2.0, 0.0) / 3.0 * 10)

  defp reputation_points(_), do: 0

  defp closed?(%{status: s}) when is_binary(s),
    do: String.contains?(String.downcase(s), ["permanently closed", "مغلق نهائي"])

  defp closed?(_), do: false

  @doc "Letter grade for a score. Calibrated so A+/A is a shortlist, not a dump."
  @spec grade(non_neg_integer()) :: String.t()
  def grade(s) when s >= 75, do: "A+"
  def grade(s) when s >= 62, do: "A"
  def grade(s) when s >= 48, do: "B"
  def grade(_), do: "C"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  # ── export ────────────────────────────────────────────────────────────

  defp export(opts) do
    import Ecto.Query, only: [from: 2]

    places =
      GmapsEx.Repo.all(from(p in GmapsEx.Place, where: like(p.input_id, "ksa-employers:%")),
        timeout: :infinity
      )

    Mix.shell().info(":: #{length(places)} employer places in DB")

    by_grade = Enum.group_by(places, &grade(score(&1)))
    for g <- ~w(A+ A B C), do: Mix.shell().info("   #{g}: #{length(Map.get(by_grade, g, []))}")

    with_email = Enum.count(places, &((&1.emails || []) != []))
    with_site = Enum.count(places, &(not blank?(&1.website)))
    Mix.shell().info(":: #{with_email} with email · #{with_site} with website")

    for {label, grouper} <- [
          {"city", &city/1},
          {"sector", &sector/1},
          {"relevance", &relevance/1}
        ] do
      Mix.shell().info(":: by #{label}")

      places
      |> Enum.group_by(grouper)
      |> Enum.sort_by(fn {_k, ps} -> -length(ps) end)
      |> Enum.each(fn {k, ps} -> Mix.shell().info("   #{k}: #{length(ps)}") end)
    end

    master = opts[:csv] || Path.join(@out_dir, "ksa-employers.csv")
    write_all(places, master)
    Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(master)}")

    if path = opts[:jsonl] do
      File.mkdir_p!(Path.dirname(path))
      GmapsEx.Output.Jsonl.write(places, path)
      Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(path)}")
    end
  end

  defp write_all(places, master_path) do
    File.mkdir_p!(Path.dirname(master_path))
    write_ranked_csv(places, master_path)

    dir = Path.dirname(master_path)

    for {sub, grouper} <- [{"by-city", &city/1}, {"by-sector", &sector/1}] do
      File.mkdir_p!(Path.join(dir, sub))

      places
      |> Enum.group_by(grouper)
      |> Enum.each(fn {k, ps} -> write_ranked_csv(ps, Path.join([dir, sub, "#{k}.csv"])) end)
    end

    # The two files he actually works from. `shortlist` is the day-one call
    # list: category-verified employer, and a way to reach it.
    shortlist =
      Enum.filter(places, fn p ->
        relevance(p) == "core" and ((p.emails || []) != [] or not blank?(p.website))
      end)

    write_ranked_csv(shortlist, Path.join(dir, "shortlist.csv"))

    contactable =
      Enum.filter(places, &((&1.emails || []) != [] or not blank?(&1.website)))

    write_ranked_csv(contactable, Path.join(dir, "contactable.csv"))
  end

  @headers ~w(
    fit_grade fit_score relevance city sector title category categories address
    emails website phone contact_method
    review_rating review_count status latitude longitude
    open_hours description owner_name place_id cid link complete_address input_id
  )

  defp write_ranked_csv(places, path) do
    rows =
      places
      |> Enum.map(&{score(&1), &1})
      |> Enum.sort_by(fn {s, p} -> {-s, -(p.review_count || 0)} end)
      |> Enum.map(fn {s, p} ->
        [
          grade(s),
          s,
          relevance(p),
          city(p),
          sector(p),
          p.title || "",
          p.category || "",
          (p.categories || []) |> Enum.join(" | "),
          p.address || "",
          (p.emails || []) |> Enum.join(" | "),
          p.website || "",
          p.phone || "",
          contact_method(p),
          to_string(p.review_rating || ""),
          to_string(p.review_count || ""),
          p.status || "",
          to_string(p.latitude || ""),
          to_string(p.longitude || ""),
          json(p.open_hours),
          p.description || "",
          (is_map(p.owner) && Map.get(p.owner, "name")) || "",
          p.place_id || "",
          p.cid || "",
          p.link || "",
          json(p.complete_address),
          p.input_id || ""
        ]
      end)

    csv =
      [@headers | rows] |> Enum.map_join("\n", fn row -> Enum.map_join(row, ",", &escape/1) end)

    # BOM so Excel opens the Arabic columns as UTF-8.
    File.write!(path, "﻿" <> csv)
  end

  defp contact_method(p) do
    cond do
      (p.emails || []) != [] -> "email"
      not blank?(p.website) -> "website"
      not blank?(p.phone) -> "phone"
      true -> "none"
    end
  end

  defp escape(v) when is_binary(v) do
    if String.contains?(v, [",", "\"", "\n", "\r"]),
      do: "\"" <> String.replace(v, "\"", "\"\"") <> "\"",
      else: v
  end

  defp escape(v), do: to_string(v)

  defp json(nil), do: ""
  defp json(m) when is_map(m) and map_size(m) == 0, do: ""
  defp json([]), do: ""
  defp json(v), do: Jason.encode!(v)

  # ── progress ──────────────────────────────────────────────────────────

  defp attach_progress_logger do
    :telemetry.attach_many(
      "gmaps-ksa-employers-progress",
      [[:gmaps_ex, :search, :ok], [:gmaps_ex, :place, :ok], [:gmaps_ex, :run, :complete]],
      fn
        [:gmaps_ex, :search, :ok], m, meta, _ ->
          if Enum.random(1..20) == 1,
            do: Mix.shell().info(":: search '#{meta[:query]}' → #{m[:count]} places")

        # place/:ok carries only cid + title (see PlaceWorker), so there is no
        # email to report here — the EmailWorker it spawns writes those later.
        [:gmaps_ex, :place, :ok], _m, meta, _ ->
          if Enum.random(1..50) == 1, do: Mix.shell().info("   + #{meta[:title]}")

        [:gmaps_ex, :run, :complete], m, _meta, _ ->
          Mix.shell().info(":: run complete (#{m[:places]} places / #{m[:seeds]} seeds)")
      end,
      nil
    )
  end

  # GmapsEx.Exiter only counts seeds that SUCCEED, so any discarded search job
  # leaves seed_completed short of seed_count and [:gmaps_ex, :run, :complete]
  # never fires (empty grid cells are normal in a grid sweep). Wait on the
  # telemetry OR on the queue draining, whichever comes first.
  defp wait_for_completion(timeout_s) do
    parent = self()

    :ok =
      :telemetry.attach(
        "gmaps-ksa-employers-wait",
        [:gmaps_ex, :run, :complete],
        fn _, _, _, _ -> send(parent, :emp_done) end,
        nil
      )

    poll_until_done(System.monotonic_time(:second) + timeout_s, 0)
  end

  @poll_ms 30_000
  @empty_polls_needed 2

  defp poll_until_done(deadline, empty_polls) do
    receive do
      :emp_done -> :ok
    after
      @poll_ms ->
        cond do
          System.monotonic_time(:second) >= deadline ->
            Mix.shell().info(":: timeout — partial results in DB")
            :ok

          empty_polls + 1 >= @empty_polls_needed and pending_jobs() == 0 ->
            Mix.shell().info(":: queue drained — #{@empty_polls_needed} empty polls")
            :ok

          pending_jobs() == 0 ->
            poll_until_done(deadline, empty_polls + 1)

          true ->
            poll_until_done(deadline, 0)
        end
    end
  end

  defp pending_jobs do
    import Ecto.Query, only: [from: 2]

    GmapsEx.Repo.one(
      from(j in "oban_jobs",
        where: j.state in ["available", "executing", "scheduled", "retryable"],
        select: count(j.id)
      )
    )
  end
end
