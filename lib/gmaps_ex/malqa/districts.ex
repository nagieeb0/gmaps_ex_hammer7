defmodule GmapsEx.Malqa.Districts do
  @moduledoc """
  Riyadh districts, and which of them are demographically twinned with Al Malqa.

  Two jobs. First, `assign/2` maps a lat/lon to a district so a brand's footprint
  can be described in terms an owner recognises. Second, `twins/0` names the
  districts that share Al Malqa's customer — a brand concentrated there but absent
  from Al Malqa is the white-space signal the whole Track A ranking rests on.

  Boxes are approximate and are **cross-checked against the scraped
  `complete_address.borough` field**, which is authoritative where present. See
  `GmapsEx.Whitespace.district_agreement/0`.
  """

  # {tag, name_ar, lat, lon, half_lat_km, half_lon_km, priority}
  # Lower priority wins on overlap, so small districts are listed before large ones.
  @districts [
    {"al-malqa", "الملقا", 24.800, 46.600, 2.0, 2.2, 1},
    {"hittin", "حطين", 24.766, 46.605, 2.0, 2.2, 1},
    {"al-yasmin", "الياسمين", 24.827, 46.646, 1.8, 2.0, 1},
    {"al-narjis", "النرجس", 24.855, 46.650, 2.0, 2.2, 1},
    {"al-nakheel", "النخيل", 24.742, 46.632, 1.5, 1.8, 1},
    {"al-sahafa", "الصحافة", 24.812, 46.647, 1.6, 1.8, 1},
    {"qurtubah", "قرطبة", 24.807, 46.755, 2.0, 2.2, 1},
    {"al-rabie", "الربيع", 24.796, 46.690, 1.6, 1.8, 1},
    {"al-aqiq", "العقيق", 24.774, 46.622, 1.5, 1.6, 1},
    {"al-ghadeer", "الغدير", 24.775, 46.672, 1.4, 1.6, 1},
    {"al-wadi", "الوادي", 24.788, 46.702, 1.4, 1.6, 1},
    {"al-mughrizat", "المغرزات", 24.765, 46.700, 1.4, 1.6, 1},

    # Non-twin Riyadh districts — present so `assign/2` rarely returns "other".
    # A high "other" rate is itself the alarm that this table is wrong.
    {"kafd", "مركز الملك عبدالله المالي", 24.766, 46.641, 1.0, 1.0, 0},
    {"diriyah", "الدرعية", 24.737, 46.575, 2.0, 2.2, 2},
    {"irqah", "عرقة", 24.715, 46.560, 2.0, 2.2, 2},
    {"al-olaya", "العليا", 24.694, 46.684, 2.0, 1.8, 2},
    {"al-sulaimaniyah", "السليمانية", 24.706, 46.704, 1.6, 1.6, 2},
    {"al-murabba", "المربع", 24.665, 46.710, 1.4, 1.4, 2},
    {"al-malaz", "الملز", 24.667, 46.735, 1.8, 1.8, 2},
    {"al-muruj", "المروج", 24.740, 46.670, 1.4, 1.6, 2},
    {"al-izdihar", "الازدهار", 24.760, 46.720, 1.6, 1.8, 2},
    {"al-nuzha", "النزهة", 24.780, 46.730, 1.6, 1.8, 2},
    {"al-taawun", "التعاون", 24.755, 46.690, 1.4, 1.6, 2},
    {"al-rawdah", "الروضة", 24.730, 46.790, 2.2, 2.4, 2},
    {"al-hamra", "الحمراء", 24.755, 46.800, 2.0, 2.2, 2},
    {"qurtubah-east", "اليرموك", 24.795, 46.800, 2.0, 2.2, 2},
    {"al-munsiyah", "المونسية", 24.800, 46.850, 2.5, 2.5, 2},
    {"al-rimal", "الرمال", 24.850, 46.860, 3.0, 3.0, 2},
    {"al-arid", "العارض", 24.890, 46.700, 3.0, 3.0, 2},
    {"al-qirawan", "القيروان", 24.870, 46.680, 2.0, 2.2, 2},
    {"al-sulay", "السلي", 24.630, 46.830, 3.0, 3.0, 2},
    {"al-shifa", "الشفا", 24.560, 46.740, 3.0, 3.0, 2},
    {"al-aziziyah", "العزيزية", 24.590, 46.780, 2.5, 2.5, 2},
    {"al-badiah", "البديعة", 24.630, 46.640, 2.5, 2.5, 2},
    {"al-shemaysi", "الشميسي", 24.640, 46.690, 1.8, 1.8, 2},
    {"tuwaiq", "طويق", 24.650, 46.570, 3.0, 3.0, 2},
    {"dhahrat-laban", "ظهرة لبن", 24.680, 46.550, 2.5, 2.5, 2},
    {"al-dar-al-baida", "الدار البيضاء", 24.560, 46.800, 3.0, 3.0, 2},
    {"al-naseem", "النسيم", 24.700, 46.830, 2.5, 2.5, 2},
    {"al-khaleej", "الخليج", 24.720, 46.840, 2.0, 2.2, 2},
    {"dq", "الحي الدبلوماسي", 24.690, 46.620, 1.5, 1.5, 1},
    {"al-mohammadiyah", "المحمدية", 24.745, 46.655, 1.2, 1.4, 1},
    {"al-raid", "الرائد", 24.720, 46.640, 1.4, 1.6, 2},
    {"umm-al-hamam", "ام الحمام", 24.710, 46.630, 1.6, 1.8, 2},
    {"al-wurud", "الورود", 24.715, 46.675, 1.4, 1.6, 2},
    {"king-salman", "حي الملك سلمان", 24.820, 46.610, 2.0, 2.2, 2},
    {"al-qadisiyah", "القادسية", 24.780, 46.870, 2.5, 2.5, 2}
  ]

  # Districts whose customer base mirrors Al Malqa's: affluent, north Riyadh,
  # villa-and-compound residential with a mature F&B strip.
  @twins ~w(al-malqa hittin al-yasmin al-narjis al-nakheel al-sahafa qurtubah
            al-rabie al-aqiq al-ghadeer al-wadi al-mughrizat)

  @type district :: {String.t(), String.t(), float(), float(), float(), float(), integer()}

  @spec all() :: [district()]
  def all, do: @districts

  @spec twins() :: [String.t()]
  def twins, do: @twins

  @spec twin?(String.t() | nil) :: boolean()
  def twin?(tag), do: tag in @twins

  @spec names_ar() :: [String.t()]
  def names_ar, do: Enum.map(@districts, fn {_t, ar, _, _, _, _, _} -> ar end)

  @doc """
  English district names as they appear in Google Maps titles and addresses.

  Derived from the tag, plus the `al-`-less variant, because Maps writes both
  ("Al Yasmin" and "Yasmin"). Needed so an English branch suffix
  ("Baskin-Robbins - Al Yasmin") is recognised as a branch designator.
  """
  @spec names_en() :: [String.t()]
  def names_en do
    Enum.flat_map(@districts, fn {tag, _ar, _, _, _, _, _} ->
      spaced = tag |> String.replace("-", " ")
      bare = String.replace_prefix(spaced, "al ", "")
      Enum.uniq([spaced, bare])
    end)
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.uniq()
  end

  @spec tag_for_name(String.t()) :: String.t() | nil
  def tag_for_name(name_ar) do
    Enum.find_value(@districts, fn {tag, ar, _, _, _, _, _} ->
      if ar == name_ar, do: tag
    end)
  end

  @doc """
  District tag for a point using *learned* centroids.

  The hand-written table below is only a seed. Google's Riyadh addresses name the
  district directly, so the real centroid and spread of every district can be
  measured from the scraped rows that carry one — see
  `GmapsEx.Whitespace.learn_centroids/1`. Hand-drawn boxes were 42% accurate against
  those labels; learned centroids are the fix, and they re-derive themselves every
  time the dataset grows.

  `centroids` is `%{tag => {lat, lon, radius_km}}`. Nearest centroid wins, provided
  the point is inside a tolerance of that district's own measured spread.
  """
  @spec assign_learned(float() | nil, float() | nil, map()) :: String.t()
  def assign_learned(nil, _, _), do: "other"
  def assign_learned(_, nil, _), do: "other"
  def assign_learned(lat, lon, centroids) when map_size(centroids) > 0 do
    centroids
    |> Enum.map(fn {tag, {clat, clon, r}} ->
      {tag, GmapsEx.Geo.haversine_km(lat, lon, clat, clon), r}
    end)
    |> Enum.filter(fn {_tag, d, r} -> d <= max(r * 1.15, 1.0) end)
    |> case do
      [] -> "other"
      cands -> cands |> Enum.min_by(fn {_t, d, r} -> d / max(r, 0.5) end) |> elem(0)
    end
  end

  def assign_learned(lat, lon, _), do: assign(lat, lon)

  @doc """
  District tag by majority vote of the `k` nearest address-labelled points.

  Riyadh districts are irregular polygons. A circle around a centroid mis-files
  everything near a boundary, which is why centroid assignment only reached ~58%
  against the address labels. Voting over the labelled points themselves respects
  whatever shape the district actually has, and it costs one pass over a few
  thousand points.

  `points` is a list of `{lat, lon, tag}`. Returns `"other"` when nothing labelled
  is close enough to justify a call.
  """
  @spec assign_knn(float() | nil, float() | nil, [{float(), float(), String.t()}], pos_integer()) ::
          String.t()
  def assign_knn(nil, _, _, _), do: "other"
  def assign_knn(_, nil, _, _), do: "other"

  def assign_knn(lat, lon, points, k \\ 7) do
    # Cheap degree-box prefilter before any trigonometry: ~3 km either way.
    dlat = 0.027
    dlon = 0.030

    near =
      points
      |> Enum.filter(fn {plat, plon, _} ->
        abs(plat - lat) <= dlat and abs(plon - lon) <= dlon
      end)

    near = if near == [], do: points, else: near

    near
    |> Enum.map(fn {plat, plon, tag} ->
      {GmapsEx.Geo.haversine_km(lat, lon, plat, plon), tag}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(k)
    |> case do
      [] ->
        "other"

      [{d, _} | _] when d > 3.0 ->
        "other"

      nearest ->
        nearest
        # Inverse-distance weighting: an immediate neighbour outvotes a far one.
        |> Enum.reduce(%{}, fn {d, tag}, acc ->
          Map.update(acc, tag, 1.0 / (d + 0.05), &(&1 + 1.0 / (d + 0.05)))
        end)
        |> Enum.max_by(&elem(&1, 1))
        |> elem(0)
    end
  end

  @doc """
  District tag from the seed table's approximate boxes.

  Fallback only — `assign_learned/3` is what the pipeline uses.
  """
  @spec assign(float() | nil, float() | nil) :: String.t()
  def assign(nil, _), do: "other"
  def assign(_, nil), do: "other"

  def assign(lat, lon) do
    @districts
    |> Enum.filter(fn {_tag, _ar, dlat, dlon, hlat, hlon, _p} ->
      abs(lat - dlat) <= hlat / 110.574 and
        abs(lon - dlon) <= hlon / (111.320 * :math.cos(dlat * :math.pi() / 180.0))
    end)
    |> case do
      [] ->
        "other"

      matches ->
        matches
        |> Enum.min_by(fn {_tag, _ar, dlat, dlon, _hlat, _hlon, p} ->
          {p, GmapsEx.Geo.haversine_km(lat, lon, dlat, dlon)}
        end)
        |> elem(0)
    end
  end

  @doc """
  District tag from the scraped address, which is authoritative where present.

  Google's Riyadh addresses carry the district by name (`… حي الملقا، الرياض`), and
  `complete_address` often has it parsed out as `borough`.
  """
  @spec from_address(map() | nil, String.t() | nil) :: String.t() | nil
  def from_address(complete_address, address) do
    borough =
      case complete_address do
        %{} = ca -> ca["borough"] || ca[:borough]
        _ -> nil
      end

    match_name(borough) || match_name(address)
  end

  defp match_name(nil), do: nil
  defp match_name(""), do: nil

  defp match_name(text) when is_binary(text) do
    folded = fold(text)

    Enum.find_value(@districts, fn {tag, ar, _, _, _, _, _} ->
      if String.contains?(folded, fold(ar)), do: tag
    end)
  end

  defp match_name(_), do: nil

  defp fold(s) do
    s
    |> String.replace(~r/[أإآٱ]/u, "ا")
    |> String.replace("ة", "ه")
    |> String.replace("ى", "ي")
  end

  @doc "Is this address on Anas Ibn Malik Road? Both spellings occur in the data."
  @spec on_anas_ibn_malik?(String.t() | nil) :: boolean()
  def on_anas_ibn_malik?(nil), do: false

  def on_anas_ibn_malik?(address) do
    folded = fold(address)
    Regex.match?(~r/انس\s*(ابن|بن)\s*مالك/u, folded) or
      String.contains?(String.downcase(address), "anas ibn malik") or
      String.contains?(String.downcase(address), "anas bin malik")
  end
end
