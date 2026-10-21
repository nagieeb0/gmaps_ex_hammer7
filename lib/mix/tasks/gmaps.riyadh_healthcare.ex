defmodule Mix.Tasks.Gmaps.RiyadhHealthcare do
  @moduledoc """
  Riyadh-wide healthcare scrape — every medical facility, ranked as a lead for
  **Asah** (`../Asah`): the KSA real-time reservation marketplace that gives each
  provider online booking plus a landing page at `/p/:slug`.

  Covers hospitals, medical complexes, polyclinics, dental, derm/cosmetic,
  labs, radiology/imaging, every doctor specialty, IVF, dialysis, physio &
  rehab, home care, pharmacies, opticians.

      mix gmaps.riyadh_healthcare                  # full sweep → healthcare/
      mix gmaps.riyadh_healthcare --dry-run        # job count only
      mix gmaps.riyadh_healthcare --sectors dental,lab,radiology

  Output lands in `healthcare/`:
    * `riyadh-healthcare-leads.csv`  — everything, ranked
    * `by-sector/<sector>.csv`       — same rows split per scrape sector
    * `by-asah-kind/<kind>.csv`      — same rows split per Asah provider kind

  The DB accumulates (upsert by place id), so partial/split runs are additive.
  Re-rank without re-scraping: `Mix.Tasks.Gmaps.RiyadhHealthcare.write_csv()`.

  ## Lead score (0–100)

  Ranked on *how much Asah has to sell them*, not on how big they are:

    * kind fit      (≤25) — clinic/doctor above lab/radiology above hospital,
                            matching `Asah.Directory.Provider.kind`
    * patient volume(≤25) — review_count log-scaled; proxy for booking demand
    * no website    (≤20) — nothing online at all → the landing page is the pitch
    * reputation    (≤10) — review_rating
    * contactable   (≤10) — phone / email present, i.e. sales can reach them
    * operating     (+5)  — permanently closed, or a non-medical Google
                            category, short-circuits the whole score to 0;
                            the no-website gap only counts once a place has
                            ≥5 reviews, so blank rows don't rank

  Grades: A+ ≥80 · A ≥72 · B ≥62 · C below — calibrated against the real
  stage-1 distribution, see `grade/1`.

  Every row carries an `asah_kind` column, so a filtered export drops straight
  into `Asah.Directory.Provider` seeds.
  """

  use Mix.Task

  @shortdoc "Scrape all Riyadh healthcare (clinics, doctors, labs, radiology) ranked as Asah leads"

  @out_dir "healthcare"

  # ── Queries: {sector, query} ──────────────────────────────────────────
  @queries [
    # ── hospital ──
    {"hospital", "مستشفى"},
    {"hospital", "hospital"},
    {"hospital", "مستشفى خاص"},
    {"hospital", "private hospital"},
    {"hospital", "مستشفى تخصصي"},
    {"hospital", "specialist hospital"},
    {"hospital", "مستشفى أطفال"},
    {"hospital", "children hospital"},
    {"hospital", "مستشفى ولادة"},
    {"hospital", "maternity hospital"},
    {"hospital", "مستشفى جامعي"},
    {"hospital", "طوارئ"},
    {"hospital", "emergency hospital"},

    # ── polyclinic (المجمعات والمستوصفات — أفضل شريحة للبرنامج) ──
    {"polyclinic", "مجمع طبي"},
    {"polyclinic", "medical complex"},
    {"polyclinic", "مجمع عيادات"},
    {"polyclinic", "polyclinic"},
    {"polyclinic", "مستوصف"},
    {"polyclinic", "dispensary"},
    {"polyclinic", "عيادات طبية"},
    {"polyclinic", "medical clinic"},
    {"polyclinic", "مركز طبي"},
    {"polyclinic", "medical center"},
    {"polyclinic", "مركز رعاية صحية أولية"},
    {"polyclinic", "primary healthcare center"},
    {"polyclinic", "عيادة عامة"},
    {"polyclinic", "general practitioner"},
    {"polyclinic", "طبيب أسرة"},
    {"polyclinic", "family medicine clinic"},
    {"polyclinic", "عيادة يوم واحد"},
    {"polyclinic", "day surgery center"},

    # ── dental ──
    {"dental", "عيادة أسنان"},
    {"dental", "dental clinic"},
    {"dental", "مركز أسنان"},
    {"dental", "dental center"},
    {"dental", "طبيب أسنان"},
    {"dental", "dentist"},
    {"dental", "مجمع أسنان"},
    {"dental", "dental complex"},
    {"dental", "تقويم أسنان"},
    {"dental", "orthodontist"},
    {"dental", "زراعة أسنان"},
    {"dental", "dental implants"},
    {"dental", "تجميل أسنان"},
    {"dental", "cosmetic dentistry"},
    {"dental", "علاج جذور"},
    {"dental", "endodontist"},
    {"dental", "أسنان أطفال"},
    {"dental", "pediatric dentist"},
    {"dental", "معمل أسنان"},
    {"dental", "dental laboratory"},

    # ── derm / cosmetic ──
    {"derm", "عيادة جلدية"},
    {"derm", "dermatology clinic"},
    {"derm", "طبيب جلدية"},
    {"derm", "dermatologist"},
    {"derm", "عيادة تجميل"},
    {"derm", "cosmetic clinic"},
    {"derm", "مركز تجميل طبي"},
    {"derm", "medical aesthetics center"},
    {"derm", "جراحة تجميل"},
    {"derm", "plastic surgery"},
    {"derm", "مركز ليزر"},
    {"derm", "laser center"},
    {"derm", "زراعة شعر"},
    {"derm", "hair transplant"},
    {"derm", "عيادة نحت الجسم"},
    {"derm", "body contouring clinic"},

    # ── lab ──
    {"lab", "مختبر طبي"},
    {"lab", "medical laboratory"},
    {"lab", "مختبر تحاليل"},
    {"lab", "analysis lab"},
    {"lab", "معمل تحاليل"},
    {"lab", "diagnostic laboratory"},
    {"lab", "مختبر تحاليل طبية"},
    {"lab", "blood test lab"},
    {"lab", "مختبر فحص الدم"},
    {"lab", "pathology lab"},
    {"lab", "مركز فحوصات مخبرية"},
    {"lab", "genetic testing lab"},
    {"lab", "مختبر وراثة"},

    # ── radiology / imaging ──
    {"radiology", "مركز أشعة"},
    {"radiology", "radiology center"},
    {"radiology", "مركز تصوير طبي"},
    {"radiology", "medical imaging center"},
    {"radiology", "أشعة مقطعية"},
    {"radiology", "CT scan center"},
    {"radiology", "رنين مغناطيسي"},
    {"radiology", "MRI center"},
    {"radiology", "أشعة سينية"},
    {"radiology", "X-ray center"},
    {"radiology", "سونار"},
    {"radiology", "ultrasound clinic"},
    {"radiology", "تصوير ثدي"},
    {"radiology", "mammography center"},
    {"radiology", "طب نووي"},
    {"radiology", "nuclear medicine"},

    # ── internal medicine & sub-specialties ──
    {"internal", "عيادة باطنية"},
    {"internal", "internal medicine clinic"},
    {"internal", "استشاري باطنية"},
    {"internal", "عيادة قلب"},
    {"internal", "cardiology clinic"},
    {"internal", "طبيب قلب"},
    {"internal", "cardiologist"},
    {"internal", "عيادة سكري"},
    {"internal", "diabetes clinic"},
    {"internal", "عيادة غدد صماء"},
    {"internal", "endocrinology clinic"},
    {"internal", "عيادة كلى"},
    {"internal", "nephrology clinic"},
    {"internal", "مركز غسيل كلى"},
    {"internal", "dialysis center"},
    {"internal", "عيادة جهاز هضمي"},
    {"internal", "gastroenterology clinic"},
    {"internal", "مركز مناظير"},
    {"internal", "endoscopy center"},
    {"internal", "عيادة صدرية"},
    {"internal", "pulmonology clinic"},
    {"internal", "عيادة روماتيزم"},
    {"internal", "rheumatology clinic"},
    {"internal", "عيادة أورام"},
    {"internal", "oncology clinic"},
    {"internal", "عيادة مخ وأعصاب"},
    {"internal", "neurology clinic"},
    {"internal", "عيادة أمراض دم"},
    {"internal", "hematology clinic"},
    {"internal", "عيادة مناعة وحساسية"},
    {"internal", "allergy and immunology clinic"},
    {"internal", "عيادة أمراض معدية"},
    {"internal", "infectious disease clinic"},

    # ── surgery ──
    {"surgery", "عيادة جراحة عامة"},
    {"surgery", "general surgery clinic"},
    {"surgery", "جراح"},
    {"surgery", "surgeon"},
    {"surgery", "جراحة سمنة"},
    {"surgery", "bariatric surgery"},
    {"surgery", "مركز تخسيس"},
    {"surgery", "obesity center"},
    {"surgery", "جراحة أوعية دموية"},
    {"surgery", "vascular surgery"},
    {"surgery", "عيادة دوالي"},
    {"surgery", "varicose veins clinic"},
    {"surgery", "جراحة مسالك بولية"},
    {"surgery", "urology clinic"},
    {"surgery", "عيادة مسالك بولية"},
    {"surgery", "urologist"},

    # ── ortho ──
    {"ortho", "عيادة عظام"},
    {"ortho", "orthopedic clinic"},
    {"ortho", "طبيب عظام"},
    {"ortho", "orthopedic surgeon"},
    {"ortho", "عيادة عمود فقري"},
    {"ortho", "spine clinic"},
    {"ortho", "مركز إصابات ملاعب"},
    {"ortho", "sports medicine center"},
    {"ortho", "عيادة مفاصل"},
    {"ortho", "joint replacement clinic"},

    # ── women & fertility ──
    {"women", "عيادة نساء وولادة"},
    {"women", "obstetrics and gynecology clinic"},
    {"women", "طبيبة نساء"},
    {"women", "gynecologist"},
    {"women", "مركز إخصاب"},
    {"women", "fertility center"},
    {"women", "أطفال أنابيب"},
    {"women", "IVF center"},
    {"women", "مركز صحة المرأة"},
    {"women", "women health center"},
    {"women", "عيادة عقم"},
    {"women", "infertility clinic"},

    # ── pediatric ──
    {"pediatric", "عيادة أطفال"},
    {"pediatric", "pediatric clinic"},
    {"pediatric", "طبيب أطفال"},
    {"pediatric", "pediatrician"},
    {"pediatric", "مركز أطفال طبي"},
    {"pediatric", "children medical center"},
    {"pediatric", "عيادة حديثي الولادة"},
    {"pediatric", "neonatology clinic"},
    {"pediatric", "مركز تطعيمات"},
    {"pediatric", "vaccination center"},

    # ── eye ──
    {"eye", "عيادة عيون"},
    {"eye", "eye clinic"},
    {"eye", "مركز عيون"},
    {"eye", "eye center"},
    {"eye", "طبيب عيون"},
    {"eye", "ophthalmologist"},
    {"eye", "تصحيح نظر"},
    {"eye", "LASIK center"},
    {"eye", "مركز بصريات"},
    {"eye", "optician"},
    {"eye", "محل نظارات طبية"},
    {"eye", "optometrist"},

    # ── ENT ──
    {"ent", "عيادة أنف وأذن وحنجرة"},
    {"ent", "ENT clinic"},
    {"ent", "طبيب أنف وأذن"},
    {"ent", "otolaryngologist"},
    {"ent", "مركز سمعيات"},
    {"ent", "hearing center"},
    {"ent", "سماعات طبية"},
    {"ent", "audiology clinic"},

    # ── psych & behavioral ──
    {"psych", "عيادة نفسية"},
    {"psych", "psychiatry clinic"},
    {"psych", "طبيب نفسي"},
    {"psych", "psychiatrist"},
    {"psych", "أخصائي نفسي"},
    {"psych", "psychologist"},
    {"psych", "مركز استشارات نفسية"},
    {"psych", "mental health center"},
    {"psych", "مركز توحد"},
    {"psych", "autism center"},
    {"psych", "مركز تخاطب"},
    {"psych", "speech therapy center"},
    {"psych", "مركز صعوبات تعلم"},
    {"psych", "learning difficulties center"},
    {"psych", "مركز علاج إدمان"},
    {"psych", "addiction treatment center"},

    # ── rehab ──
    {"rehab", "مركز علاج طبيعي"},
    {"rehab", "physiotherapy center"},
    {"rehab", "عيادة علاج طبيعي"},
    {"rehab", "physical therapy clinic"},
    {"rehab", "مركز تأهيل طبي"},
    {"rehab", "rehabilitation center"},
    {"rehab", "مركز أطراف صناعية"},
    {"rehab", "prosthetics center"},
    {"rehab", "مركز علاج وظيفي"},
    {"rehab", "occupational therapy"},
    {"rehab", "مركز كايروبراكتيك"},
    {"rehab", "chiropractic clinic"},

    # ── nutrition ──
    {"nutrition", "عيادة تغذية"},
    {"nutrition", "nutrition clinic"},
    {"nutrition", "أخصائي تغذية"},
    {"nutrition", "dietitian"},
    {"nutrition", "عيادة تغذية علاجية"},
    {"nutrition", "clinical nutrition center"},

    # ── home care ──
    {"homecare", "رعاية صحية منزلية"},
    {"homecare", "home healthcare"},
    {"homecare", "تمريض منزلي"},
    {"homecare", "home nursing services"},
    {"homecare", "زيارة طبيب منزلية"},
    {"homecare", "doctor home visit"},
    {"homecare", "شركة رعاية منزلية"},
    {"homecare", "home care company"},

    # ── pharmacy ──
    {"pharmacy", "صيدلية"},
    {"pharmacy", "pharmacy"},
    {"pharmacy", "صيدلية مجمع طبي"},
    {"pharmacy", "community pharmacy"},
    {"pharmacy", "مستودع أدوية"},
    {"pharmacy", "pharmaceutical warehouse"},

    # ── medical supply / support ──
    {"supply", "شركة مستلزمات طبية"},
    {"supply", "medical supplies company"},
    {"supply", "شركة أجهزة طبية"},
    {"supply", "medical equipment company"},
    {"supply", "مركز أكسجين منزلي"},
    {"supply", "home oxygen supplier"},

    # ── alternative ──
    {"alt", "طب بديل"},
    {"alt", "alternative medicine"},
    {"alt", "مركز حجامة"},
    {"alt", "cupping therapy center"},
    {"alt", "عيادة طب صيني"},
    {"alt", "acupuncture clinic"}
  ]

  # ── Riyadh zones: {tag, lat, lon, half_w_km, half_h_km, cell_km} ───────
  @zones [
    {"central", 24.69, 46.69, 5.0, 5.0, 2.0},
    {"north", 24.79, 46.63, 7.0, 5.0, 2.0},
    {"northeast", 24.84, 46.73, 5.0, 4.0, 2.0},
    {"east", 24.72, 46.82, 6.0, 5.0, 2.0},
    {"southeast", 24.58, 46.78, 5.0, 4.0, 2.0},
    {"south", 24.55, 46.68, 6.0, 5.0, 2.0},
    {"southwest", 24.55, 46.55, 5.0, 4.0, 2.0},
    {"west", 24.65, 46.55, 5.0, 5.0, 2.0},
    {"northwest", 24.78, 46.55, 5.0, 4.0, 2.0},
    {"dq", 24.69, 46.62, 3.0, 3.0, 1.5},
    {"kafd", 24.77, 46.65, 2.0, 2.0, 1.5},
    {"northern-strip", 24.82, 46.68, 4.0, 6.0, 2.0},
    {"king-salman", 24.72, 46.60, 3.0, 3.0, 2.0},
    {"diriyah", 24.74, 46.57, 3.0, 3.0, 2.0},
    {"industrial-city", 24.52, 46.88, 5.0, 4.0, 2.5}
  ]

  # Fit by Asah provider kind (≤25 pts). Mirrors the `kind` enum in
  # Asah.Directory.Provider — clinics and solo doctors are the ideal tenant,
  # hospitals score low (own booking stack, enterprise sales cycle), and
  # anything outside Asah's five kinds is parked at "other".
  @kind_fit %{
    "clinic" => 25,
    "doctor" => 24,
    "lab" => 20,
    "radiology" => 20,
    "hospital" => 12,
    "other" => 5
  }

  @switches [
    csv: :string,
    jsonl: :string,
    dry_run: :boolean,
    timeout: :integer,
    search_concurrency: :integer,
    place_concurrency: :integer,
    sectors: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    queries = filter_queries(opts[:sectors])
    seeds = build_seeds(queries)

    Mix.shell().info("""
    :: Riyadh Healthcare Leads Scraper → #{@out_dir}/
    :: #{length(queries)} queries × #{length(@zones)} zones = #{length(seeds)} seed jobs
    :: sectors: #{queries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")}
    """)

    if opts[:dry_run] do
      for {tag, _, _, hw, hh, cell} <- @zones do
        cells = grid_count(hw, hh, cell)

        Mix.shell().info(
          "   #{tag}: #{cells} cells × #{length(queries)} = #{cells * length(queries)} jobs"
        )
      end

      Mix.shell().info(":: total #{length(seeds)} seed jobs — dry-run, nothing enqueued")
      System.halt(0)
    end

    Mix.Task.run("app.start")

    sc = opts[:search_concurrency] || 10
    pc = opts[:place_concurrency] || 20
    Oban.scale_queue(queue: :search, limit: sc)
    Oban.scale_queue(queue: :place, limit: pc)
    Mix.shell().info(":: concurrency search=#{sc} place=#{pc}")

    {:ok, n} = GmapsEx.Runner.start(seeds)
    Mix.shell().info(":: enqueued #{n} jobs — DB accumulates, split runs are additive")

    attach_progress_logger()
    wait_for_completion(opts[:timeout] || 8 * 60 * 60)

    export(opts)
  end

  # ── seeds ─────────────────────────────────────────────────────────────

  defp filter_queries(nil), do: @queries

  defp filter_queries(csv) do
    wanted = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

    case Enum.filter(@queries, fn {tag, _} -> MapSet.member?(wanted, tag) end) do
      [] ->
        Mix.raise(
          "no queries match --sectors #{csv}. Available: " <>
            (@queries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", "))
        )

      filtered ->
        filtered
    end
  end

  defp build_seeds(queries) do
    for {zone, lat, lon, hw, hh, cell} <- @zones,
        {lat_c, lon_c} <- grid(lat, lon, hw, hh, cell),
        {sector, query} <- queries do
      %{
        query: query,
        input_id: "riyadh-healthcare:#{zone}:#{sector}",
        lat: lat_c,
        lon: lon_c,
        zoom: 14,
        lang: if(String.match?(query, ~r/^[\x00-\x7F]+$/), do: "en", else: "ar"),
        gl: "sa"
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

  @doc "Sector tag parsed back out of `input_id`."
  @spec sector(GmapsEx.Place.t()) :: String.t()
  def sector(%{input_id: "riyadh-healthcare:" <> rest}) do
    case String.split(rest, ":") do
      [_zone, sector | _] -> sector
      _ -> "unknown"
    end
  end

  def sector(_), do: "unknown"

  @doc """
  Asah provider `kind` this place maps to — the enum in
  `Asah.Directory.Provider`: `doctor | hospital | clinic | lab | radiology`.
  Anything outside Asah's five kinds is `"other"`.

  Individual practitioners are told apart from facilities by title prefix
  (د. / دكتور / Dr) — Google returns both under the same specialty query.
  """
  # Exact Google category → Asah kind. Built from the 622 distinct categories
  # this scrape actually returned; these entries cover ~83% of all rows.
  #
  # Substring keyword matching was tried first and does not converge: "Optician"
  # matches the `optic` stem, "Massage spa" and a restaurant categorised
  # "مركز علاج اضطرابات" match `علاج`, and every keyword added to plug one leak
  # opened another. The category vocabulary is finite and its head is
  # concentrated, so an explicit table terminates where keywords do not.
  # The keyword heuristic below survives only as the fallback for the ~17% tail.
  #
  # "other" = real, but not something Asah lists: retail, suppliers, gyms,
  # nurseries, veterinary, and B2B labs that serve clinics rather than patients.
  @category_kind %{
    # ── hospital ──
    "مستشفى" => "hospital",
    "hospital" => "hospital",
    "مستشفى خاصة" => "hospital",
    "private hospital" => "hospital",
    "maternity hospital" => "hospital",
    "مستشفى جامعي" => "hospital",
    "قسم في المستشفى" => "hospital",
    "hospital department" => "hospital",
    # ── lab (patient-facing diagnostics) ──
    "مختبر طبي" => "lab",
    "medical laboratory" => "lab",
    "laboratory" => "lab",
    "مختبر" => "lab",
    # ── radiology ──
    "مركز أشعة" => "radiology",
    "radiology" => "radiology",
    "diagnostic center" => "radiology",
    "medical diagnostic imaging center" => "radiology",
    "mri center" => "radiology",
    # ── doctor (an individual practitioner) ──
    "طبيب" => "doctor",
    "doctor" => "doctor",
    "طبيب أسنان" => "doctor",
    "dentist" => "doctor",
    "طبيب أمراض جلدية" => "doctor",
    "dermatologist" => "doctor",
    "أخصائي تغذية" => "doctor",
    "dietitian" => "doctor",
    "nutritionist" => "doctor",
    "طبيب الأسرة الممارس" => "doctor",
    "family practice physician" => "doctor",
    "orthodontist" => "doctor",
    "طبيب عيون" => "doctor",
    "طبيب نفسي" => "doctor",
    "plastic surgeon" => "doctor",
    "جراح تجميل" => "doctor",
    "طبيب تجميل أسنان" => "doctor",
    "cosmetic dentist" => "doctor",
    "obstetrician-gynecologist" => "doctor",
    "طبيب أطفال" => "doctor",
    "أخصائي علاج طبيعي" => "doctor",
    "osteopath" => "doctor",
    "أخصائي تجبير عظام" => "doctor",
    "optometrist" => "doctor",
    "internist" => "doctor",
    # ── clinic ──
    # NOTE: the deliberately generic labels — "مركز طبي", "عيادة طبية",
    # "Medical Center/Clinic/Group", "المركز الطبي العام", "Medical office" —
    # are NOT listed here. Google hangs them on imaging and lab centres just as
    # often as on clinics, so they fall through to the sector tie-break below.
    # Adding them here would silently flatten every such centre into "clinic".
    "عِيادة أسنان" => "clinic",
    "عيادة أسنان" => "clinic",
    "dental clinic" => "clinic",
    "مستوصف عام" => "clinic",
    "عيادة متخصصة" => "clinic",
    "specialized clinic" => "clinic",
    "عيادة علاج طبيعي" => "clinic",
    "physical therapy clinic" => "clinic",
    "skin care clinic" => "clinic",
    "عيادة للعناية بالبشرة" => "clinic",
    "dialysis center" => "clinic",
    "مركز الغسيل الكلوي" => "clinic",
    "rehabilitation center" => "clinic",
    "مركز إعادة التأهيل" => "clinic",
    "عيادة جراحة التجميل" => "clinic",
    "plastic surgery clinic" => "clinic",
    "خدمة الصحة النفسية" => "clinic",
    "mental health service" => "clinic",
    "mental health clinic" => "clinic",
    "عيادة الصحة النفسية" => "clinic",
    "walk-in clinic" => "clinic",
    "public medical center" => "clinic",
    "ophthalmology clinic" => "clinic",
    "عيادة طب العيون" => "clinic",
    "مركز عناية بالعيون" => "clinic",
    "eye care center" => "clinic",
    "الخدمات الطبية المحلية" => "clinic",
    "home health care service" => "clinic",
    "رعاية صحية في المنزل" => "clinic",
    "مركز الرعاية العاجلة" => "clinic",
    "غرفة طوارئ" => "clinic",
    # ── other: real places, not Asah providers ──
    "صيدلية" => "other",
    "pharmacy" => "other",
    "pharmaceutical company" => "other",
    "شركة أدوية" => "other",
    "الصيدلة البيطرية" => "other",
    "veterinary pharmacy" => "other",
    "optician" => "other",
    "محل بصريات" => "other",
    "متجر نظارات شمسية" => "other",
    "sunglasses store" => "other",
    "حضانة أطفال" => "other",
    "رياض أطفال" => "other",
    "مركز لرعاية الأطفال" => "other",
    "medical equipment supplier" => "other",
    "متجر مستلزمات طبية" => "other",
    "medical supply store" => "other",
    "مورد معدات طبية" => "other",
    "fitness center" => "other",
    "gym" => "other",
    "pilates studio" => "other",
    "beauty salon" => "other",
    "صالون تجميل" => "other",
    "خبير تجميل" => "other",
    "massage spa" => "other",
    "مساج وسبا" => "other",
    "أخصائي مساج رياضي" => "other",
    "مستودع" => "other",
    "warehouse" => "other",
    "corporate office" => "other",
    "مكتب الشركات" => "other",
    "مكتب حكومي" => "other",
    "government office" => "other",
    "المركز التعليمي" => "other",
    "مركز تدريب" => "other",
    "training center" => "other",
    "education center" => "other",
    "مسجد" => "other",
    "موقف سيارات" => "other",
    "parking lot" => "other",
    "department store" => "other",
    "مركز تسوق" => "other",
    "vitamin & supplements store" => "other",
    "herbal medicine store" => "other",
    "متجر الأجهزة المساعدة على السماع" => "other",
    "health and beauty shop" => "other",
    "جمعية / منظمة" => "other",
    "association / organization" => "other",
    "مستشفى بيطري" => "other",
    "veterinarian" => "other",
    "alternative medicine practitioner" => "other",
    "ممارس طب بديل" => "other",
    "خبير علاج يدوي" => "other",
    # B2B: serves dentists, never books a patient
    "dental laboratory" => "other",
    "مختبر الأسنان" => "other",
    "معمل أسنان" => "other",
    "خدمة إسعاف" => "other",
    "health consultant" => "other",
    "مستشار صحي" => "other",
    "uniform store" => "other",
    "متجر للزي الموحد" => "other",
    "manufacturer" => "other",
    "مصنع" => "other"
  }

  # Defined before asah_kind/1 — a module attribute is read at its point of
  # use during compilation, so declaring these below the function would silently
  # inline `nil` and crash String.contains?/2 at runtime.
  #
  # Checked before the clinical kinds: a pharmacy or medical-supply store is
  # not something Asah lists, whatever query turned it up.
  @other_cats ["صيدل", "مستودع", "شركة أدوية", "pharmac", "warehouse", "supply", "متجر", "store"]
  @hospital_cats ["مستشفى", "hospital"]
  @radiology_cats [
    "أشعة",
    "سونار",
    "تصوير طبي",
    "رنين",
    "radiolog",
    "imaging",
    "mri",
    "ct scan",
    "ultrasound",
    "mammograph",
    "nuclear medicine",
    "x-ray"
  ]
  @lab_cats ["مختبر", "معمل تحالي", "laborator", "pathology"]

  @spec asah_kind(GmapsEx.Place.t()) :: String.t()
  def asah_kind(p) do
    # Google's own category wins over the query sector.
    #
    # `input_id` records whichever query last upserted the row, and a place is
    # re-found by many queries across a grid sweep — so the sector is
    # last-write-wins, not the place's real type. Stage 2 left 397 rows tagged
    # sector=hospital whose category is plainly a clinic; ranking those as
    # hospitals (fit 12) instead of clinics (fit 25) buries real leads.
    # Sector is only the fallback for rows not yet enriched with a category.
    # Downcased: every list below is lowercase, and Google mixes cases freely
    # ("Medical Center" vs "medical clinic").
    cat =
      [p.category | p.categories || []]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      cat == "" -> kind_from_sector(p)
      # Exact table first — it decides ~83% of rows and is the only part of
      # this function that cannot be defeated by a shared word stem.
      kind = @category_kind[primary_category(p)] -> kind
      String.contains?(cat, @other_cats) -> "other"
      String.contains?(cat, @hospital_cats) -> "hospital"
      String.contains?(cat, @radiology_cats) -> "radiology"
      String.contains?(cat, @lab_cats) -> "lab"
      # "مركز طبي" / "Medical Center" is what Google labels a great many
      # imaging and lab centres too, so it decides nothing on its own. Only
      # here — where the category is generic rather than wrong — is the query
      # sector worth consulting again.
      # Before the sector fallback: a place titled "د. أحمد ..." is that
      # doctor's practice, whichever query happened to surface it.
      solo_practitioner?(p.title) -> "doctor"
      generic_medical?(cat) -> generic_kind(p)
      true -> "clinic"
    end
  end

  @generic_cats [
    "مركز طبي",
    "مجمع طبي",
    "عيادة طبية",
    "المركز الطبي",
    "medical center",
    "medical centre",
    "medical clinic",
    "medical group",
    "clinic"
  ]

  defp generic_medical?(cat), do: String.contains?(cat, @generic_cats)

  # Google's primary category only — the extra `categories` are noisy
  # ("متجر" tacked onto a pharmacy) and would defeat an exact lookup.
  defp primary_category(p) do
    if blank?(p.category), do: nil, else: String.downcase(p.category)
  end

  # A generic *medical* category settles one thing even when it settles nothing
  # else: the place is a medical facility. So the sector may break the tie
  # between the clinical kinds, but it may not drag the row back to "other" —
  # a row Google calls "مركز طبي" is not a pharmacy however it was found.
  defp generic_kind(p) do
    case kind_from_sector(p) do
      "other" -> "clinic"
      kind -> kind
    end
  end

  defp kind_from_sector(p) do
    case sector(p) do
      "hospital" -> "hospital"
      "lab" -> "lab"
      "radiology" -> "radiology"
      s when s in ~w(pharmacy supply) -> "other"
      _ -> if solo_practitioner?(p.title), do: "doctor", else: "clinic"
    end
  end

  defp solo_practitioner?(nil), do: false

  defp solo_practitioner?(title),
    do: String.match?(title, ~r/^\s*(د\.|د\s|دكتور|دكتورة|الدكتور|الدكتورة|Dr\.?\s)/iu)

  @doc """
  Lead score 0–100 for an Asah sale — online booking + a landing page per
  provider. See the @moduledoc for the weights and the reasoning.

  Pure function of the DB row: tune it and re-run `write_csv/0`, no re-scrape.
  """
  @spec score(GmapsEx.Place.t()) :: non_neg_integer()
  def score(p) do
    reviews = p.review_count || 0
    rating = p.review_rating || 0.0

    fit = Map.get(@kind_fit, asah_kind(p), 5)

    # Not a lead, whatever else it scores: closed, filed under a non-medical
    # category, or an "other" kind — a pharmacy, optician or supplier is a real
    # medical business but takes no appointments, so Asah has nothing to sell
    # it. All three stay in the CSV as C rather than being dropped, so the
    # coverage the user asked for is intact and every exclusion is auditable.
    if closed?(p) or not medical?(p) or asah_kind(p) == "other" do
      0
    else
      live_score(p, reviews, rating, fit)
    end
  end

  defp live_score(p, reviews, rating, fit) do
    # Patient flow ≈ demand for appointment booking. The single strongest
    # signal, so it carries the most weight.
    # log-scaled: 0 rev → 0, 10 → ~18, 100 → ~30 (capped), 1000 → 30
    volume = if reviews > 0, do: min(30, round(9.0 * :math.log(reviews + 1))), else: 0

    reputation =
      cond do
        rating >= 4.5 -> 15
        rating >= 4.0 -> 12
        rating >= 3.5 -> 7
        rating > 0.0 -> 3
        true -> 0
      end

    # A nudge, not a gate. Asah is a marketplace plus booking, not just a
    # landing page: a clinic that already has a website still has no online
    # booking and no marketplace demand, and will happily sign. An earlier
    # version scored this 20 — that split a market which is 49% with-website
    # / 51% without almost in half on a signal that disqualifies nobody.
    # Keep it small enough that a busy well-reviewed clinic with a website
    # still outranks a quiet one without.
    no_site = if reviews >= 5 and blank?(p.website), do: 10, else: 0

    # ponytail: two terms were removed after the data showed they carried no
    # signal at all — a constant term ranks nothing:
    #   * "no booking link": `reservations` was empty on 7,817/7,817 rows
    #   * email present:     `emails` was empty on 4,315/4,315 providers,
    #     because seeds run with extract_emails: false
    # Both columns are still exported as raw data. Re-add either term only
    # once a scrape actually populates the field.
    phone = if blank?(p.phone), do: 0, else: 15

    fit + volume + reputation + no_site + phone + 5
  end

  defp closed?(p), do: p.status in ["Permanently closed", "مغلق نهائيًا", "مغلق نهائيا"]

  # Google answers a specialty query with whatever is nearby, so a bowling
  # centre lands under "derm" and a gas-cylinder supplier under "lab". Those
  # rows otherwise score A+ (high reviews, no website). Gate on Google's OWN
  # category rather than the title — it is the cleaner signal.
  @medical_terms ~w(
    عياد مستشفى مستوصف طبي طبيب أسنان مختبر معمل أشعة تحالي صيدل علاج تجميل
    صحي صحة تمريض جراح نفسي تخاطب تأهيل تغذي بصري نظار سماعات ولادة عيون
    غسيل كلوي كلى طوارئ عاجلة باطن مسالك نساء أنف أذن سمع نطق مناظير
    clinic hospital medical medicine doctor physician dentist dental
    laborator radiolog imaging x-ray health pharmac therap surg dermatolog
    optic optometr audiolog nurs diagnostic orthodont psychiatr psycholog
    nutrition dietitian internist urgent care emergency dialysis obstetric
    gynecolog pediatric urolog cardiolog neurolog oncolog ophthalm orthoped
    anesthes midwif chiropract podiat allerg endocrin gastro rheumat pulmon
    hematolog immunolog
  )

  # Checked FIRST and wins: these categories share a stem with a medical one
  # but are not providers. "صالون تجميل" (beauty salon) matches تجميل exactly
  # like "عيادة جراحة التجميل" (cosmetic surgery clinic) does — only the salon
  # half is wrong, so the allowlist alone cannot separate them.
  # Kept narrow on purpose: "مكتب حكومي" not bare "مكتب", so a medical office
  # is not caught by accident.
  @non_medical_terms [
    "صالون",
    "تزيين",
    "حلاق",
    "خبير تجميل",
    "متجر",
    "محل",
    "مصنع",
    "مكتب حكومي",
    "مكتب الشركات",
    "مكتبة",
    "جامعة",
    "مدرسة",
    "المركز التعليمي",
    "ترفيه",
    "مركز تدريب",
    "فندق",
    "مطعم",
    "بيطري",
    "عقار",
    "موقف",
    "تأشيرات",
    "ترجمة",
    "طباعة",
    "استوديو",
    "salon",
    "store",
    "shop",
    "supplier",
    "factory",
    "manufacturer",
    "corporate office",
    "government office",
    "university",
    "school",
    "training",
    "bowling",
    "laser tag",
    "amusement",
    "parking",
    "apartment",
    "housing",
    "veterinar",
    "cannabis",
    "uniform",
    "engineering",
    "soil testing",
    "association",
    "education",
    "photograph",
    "translat",
    "printing",
    "hotel",
    "restaurant"
  ]

  @doc """
  Does Google's own category for this place look medical?

  `true` when the category is blank — search-only rows have not been enriched
  by the place worker yet, and dropping them would lose real leads.
  """
  @spec medical?(GmapsEx.Place.t()) :: boolean()
  def medical?(p) do
    # ponytail: substring match on stems, so a few Arabic prefixes slip through.
    # Both lists were built from the 318 distinct categories the stage-1 scrape
    # actually returned, not guessed. Re-check them against a fresh
    # `group by category` after any sweep that adds new sectors.
    haystack =
      [p.category | p.categories || []]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      haystack == "" -> true
      String.contains?(haystack, @non_medical_terms) -> false
      true -> String.contains?(haystack, @medical_terms)
    end
  end

  @doc """
  A+ / A / B / C from `score/1`.

  Cut points calibrated against the real stage-1 distribution (3,166 Riyadh
  places), not guessed: A+ is roughly the top decile, A the next ~15%, B the
  next ~25%. The first pass used 70/55/40 and graded 66% of the list A+, which
  ranks nothing. Recalibrate here if a later sweep shifts the distribution —
  `write_csv/0` re-grades from the DB, no re-scrape.
  """
  @spec grade(non_neg_integer()) :: String.t()
  def grade(s) when s >= 87, do: "A+"
  def grade(s) when s >= 78, do: "A"
  def grade(s) when s >= 62, do: "B"
  def grade(_), do: "C"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # ── export ────────────────────────────────────────────────────────────

  @doc """
  Re-export every ranked CSV from current DB state, no scraping.
  Returns the number of places written.
  """
  @spec write_csv() :: non_neg_integer()
  def write_csv do
    import Ecto.Query, only: [from: 2]

    # timeout: :infinity — tens of thousands of rows with big JSONB columns
    # blow past the 15s default.
    places =
      GmapsEx.Repo.all(from(p in GmapsEx.Place, where: like(p.input_id, "riyadh-healthcare:%")),
        timeout: :infinity
      )

    write_all(places, Path.join(@out_dir, "riyadh-healthcare-leads.csv"))
    length(places)
  end

  defp export(opts) do
    import Ecto.Query, only: [from: 2]

    places =
      GmapsEx.Repo.all(from(p in GmapsEx.Place, where: like(p.input_id, "riyadh-healthcare:%")),
        timeout: :infinity
      )

    Mix.shell().info(":: #{length(places)} healthcare places in DB")

    by_grade = Enum.group_by(places, &grade(score(&1)))
    for g <- ~w(A+ A B C), do: Mix.shell().info("   #{g}: #{length(Map.get(by_grade, g, []))}")

    for {label, grouper} <- [{"asah kind", &asah_kind/1}, {"sector", &sector/1}] do
      Mix.shell().info(":: by #{label}")

      places
      |> Enum.group_by(grouper)
      |> Enum.sort_by(fn {_k, ps} -> -length(ps) end)
      |> Enum.each(fn {k, ps} -> Mix.shell().info("   #{k}: #{length(ps)}") end)
    end

    csv_path = opts[:csv] || Path.join(@out_dir, "riyadh-healthcare-leads.csv")
    write_all(places, csv_path)
    Mix.shell().info(":: wrote #{length(places)} places to #{Path.expand(csv_path)}")

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

    for {sub, grouper} <- [{"by-sector", &sector/1}, {"by-asah-kind", &asah_kind/1}] do
      File.mkdir_p!(Path.join(dir, sub))

      places
      |> Enum.group_by(grouper)
      |> Enum.each(fn {k, ps} -> write_ranked_csv(ps, Path.join([dir, sub, "#{k}.csv"])) end)
    end
  end

  @headers ~w(
    lead_grade lead_score asah_kind sector looks_medical title category
    categories address
    phone website emails has_website has_booking review_rating review_count
    reviews_per_rating status latitude longitude open_hours description
    owner_name place_id cid link complete_address about input_id
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
          asah_kind(p),
          sector(p),
          if(medical?(p), do: "yes", else: "no"),
          p.title || "",
          p.category || "",
          (p.categories || []) |> Enum.join(" | "),
          p.address || "",
          p.phone || "",
          p.website || "",
          (p.emails || []) |> Enum.join(" | "),
          if(blank?(p.website), do: "no", else: "yes"),
          if((p.reservations || []) == [], do: "no", else: "yes"),
          to_string(p.review_rating || ""),
          to_string(p.review_count || ""),
          json(p.reviews_per_rating),
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
          json(p.about),
          p.input_id || ""
        ]
      end)

    csv =
      [@headers | rows]
      |> Enum.map_join("\n", fn row -> Enum.map_join(row, ",", &escape/1) end)

    # BOM so Excel opens the Arabic columns as UTF-8.
    File.write!(path, "﻿" <> csv)
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
      "gmaps-riyadh-healthcare-progress",
      [[:gmaps_ex, :search, :ok], [:gmaps_ex, :place, :ok], [:gmaps_ex, :run, :complete]],
      fn
        [:gmaps_ex, :search, :ok], m, meta, _ ->
          if Enum.random(1..20) == 1,
            do: Mix.shell().info(":: search '#{meta[:query]}' → #{m[:count]} places")

        [:gmaps_ex, :place, :ok], m, meta, _ ->
          if (m[:review_rating] || 0) >= 4.0 and (m[:review_count] || 0) >= 50 do
            Mix.shell().info(
              "   ★ #{meta[:title]} (#{m[:review_rating]}★, #{m[:review_count]} reviews, #{meta[:phone] || "no phone"})"
            )
          end

        [:gmaps_ex, :run, :complete], m, _meta, _ ->
          Mix.shell().info(":: run complete (#{m[:places]} places / #{m[:seeds]} seeds)")
      end,
      nil
    )
  end

  # GmapsEx.Exiter only counts seeds that SUCCEED, so any discarded search job
  # leaves seed_completed permanently short of seed_count and the
  # [:gmaps_ex, :run, :complete] event never fires. Stage 1 hit this: 1,843
  # seeds discarded as :empty_business_list (empty grid cells — normal for a
  # grid sweep), queue fully drained, task still hanging.
  #
  # So wait on the telemetry OR on the queue actually draining, whichever
  # comes first. Draining is the ground truth; the event is just the fast path.
  defp wait_for_completion(timeout_s) do
    parent = self()

    :ok =
      :telemetry.attach(
        "gmaps-riyadh-healthcare-wait",
        [:gmaps_ex, :run, :complete],
        fn _, _, _, _ -> send(parent, :hc_done) end,
        nil
      )

    deadline = System.monotonic_time(:second) + timeout_s
    poll_until_done(deadline, 0)
  end

  @poll_ms 30_000
  # Two consecutive empty polls before calling it: one empty reading can happen
  # between a search job finishing and the place jobs it spawns being inserted.
  @empty_polls_needed 2

  defp poll_until_done(deadline, empty_polls) do
    receive do
      :hc_done -> :ok
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
