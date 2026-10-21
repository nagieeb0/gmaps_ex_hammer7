defmodule GmapsEx.Brand do
  @moduledoc """
  Group scraped branches into brands.

  Google Maps has no chain field — `title` is one opaque string ("دوز - فرع الملقا").
  Brand membership is the unit of analysis for every white-space question, so it has
  to be derived. Three keys, in order of trustworthiness:

    1. the registrable domain of `website` — branches of a chain share one
    2. a shared `phone` — the `فروع بنفس الرقم` signal, already proven on this market
    3. a normalized `title` — last resort, and the one that needs auditing

  Keys are namespaced (`"d:"`, `"p:"`, `"t:"`, `"s:"`) so a domain key can never
  collide with a title key.
  """

  @type key :: String.t()
  @type source :: :domain | :phone | :title | :singleton

  # Real domains that are shared by unrelated businesses. Keying on these would
  # merge every restaurant in a mall into one "brand".
  @never_a_brand ~w(
    hungerstation.com jahez.net talabat.com thechefz.com mrsool.co shgardi.app
    ninja.sa toyou.io careem.com deliveroo.com ubereats.com order.online
    instagram.com facebook.com twitter.com x.com tiktok.com snapchat.com
    linkedin.com youtube.com wa.me whatsapp.com linktr.ee taplink.cc beacons.ai
    msha.ke bit.ly cutt.ly
    cenomi.com alhokair.com riyadhpark.com granadamall.com.sa nakheelmall.sa
    panoramamall.com.sa roshn.sa boulevardriyadhcity.com
    wix.com wordpress.com blogspot.com weebly.com shopify.com zyro.com
    godaddysites.com google.com goo.gl
    opentable.com resy.com eatapp.co quandoo.com
  )

  # Hosts where the subdomain is the brand and the registrable domain is not.
  @subdomain_significant ~w(business.site wixsite.com myshopify.com sites.google.com square.site)

  @two_level_suffixes ~w(com.sa org.sa net.sa gov.sa edu.sa com.eg org.eg net.eg
                         co.uk com.tr com.kw com.bh com.qa com.om ae.org)

  # Normalized titles so generic that dozens of unrelated shops share them.
  @too_generic ~w(قهوه كافيه مطعم مطاعم بوفيه مخبز حلويات شاورما بقاله بقالة سوبرماركت
                  coffee cafe restaurant burger bakery juice market supermarket food)

  # Leading/trailing nouns that describe the category, not the brand.
  @generic_affixes ~w(مطعم مطاعم كافيه كافية مقهى مقاهي محل محلات شركة مؤسسة مجموعة
                      بيت صالة ركن مخبز مخبزة حلويات restaurant restaurants cafe
                      café coffee the)

  @doc """
  Derive `{key, source}` for one place in isolation.

  The phone key is unavailable here by construction — "is this number shared by
  several branches?" cannot be answered from one row. Use `key_all/1` for a real
  dataset; this exists for unit tests and one-off lookups.
  """
  @spec brand_key(map()) :: {key(), source()}
  def brand_key(place) do
    website = fetch(place, :website)
    title = fetch(place, :title)

    cond do
      (d = registrable_domain(website)) != nil ->
        {"d:" <> d, :domain}

      (t = normalize_title(title)) != "" and String.length(t) >= 2 and t not in @too_generic ->
        {"t:" <> t, :title}

      true ->
        {"s:" <> to_string(fetch(place, :data_id) || :erlang.unique_integer([:positive])),
         :singleton}
    end
  end

  @doc """
  Multi-pass keying over a whole set of places.

  Two things can only be seen across the whole set, and both are load-bearing:

    * **Ordering-platform domains.** `tryorder.net`, `yallaqrcodes.com`, `taker.io`
      and the like give every restaurant its own subdomain. Keying on the
      registrable domain merged 48 unrelated restaurants into one "brand". Any
      domain serving 3+ distinct subdomains is treated as a platform and the full
      host becomes the key — self-calibrating, so a platform nobody has heard of
      yet is handled the same way.
    * **Shared phone numbers.** A number on 2+ websiteless places is a chain's
      central line — the `فروع بنفس الرقم` signal.
  """
  @spec key_all([map()]) :: [{map(), key(), source()}]
  def key_all(places) do
    platforms = detect_platforms(places)
    shared_phones =
      places
      |> Enum.filter(&(registrable_domain(fetch(&1, :website)) == nil))
      |> Enum.map(&normalize_phone(fetch(&1, :phone)))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_p, n} -> n >= 2 end)
      |> MapSet.new(fn {p, _n} -> p end)

    Enum.map(places, fn place ->
      website = fetch(place, :website)
      phone = normalize_phone(fetch(place, :phone))
      title = fetch(place, :title)

      {key, source} =
        cond do
          (d = brand_domain(website, platforms)) != nil ->
            {"d:" <> d, :domain}

          phone != nil and MapSet.member?(shared_phones, phone) ->
            {"p:" <> phone, :phone}

          (t = normalize_title(title)) != "" and String.length(t) >= 2 and t not in @too_generic ->
            {"t:" <> t, :title}

          true ->
            {"s:" <> to_string(fetch(place, :data_id) || :erlang.unique_integer([:positive])),
             :singleton}
        end

      {place, alias_for(key), source}
    end)
  end

  @doc """
  Domains shared by unrelated businesses — ordering, booking and QR-menu platforms,
  site builders, directory listings.

  Two independent tells, because platforms identify their tenants in different ways:

    * **Subdomain fan-out** — `pizzaexpress.tryorder.net`, `bebax-coffee.yallaqrcodes.com`.
    * **Title diversity** — `requeue.net/?id=…` puts the tenant in a query string, so
      every place shares one host. What gives it away is that the places have
      *different names*: a real chain's branches share a name root, a platform's do
      not. Without this check `requeue.net` merged ten unrelated restaurants —
      ملفا, بيراتا, White Flame, كوجه — into one ten-branch "chain" that then
      ranked first.

  Detection is structural, so a platform nobody has heard of yet is caught too.
  """
  @spec detect_platforms([map()], pos_integer()) :: MapSet.t()
  def detect_platforms(places, min_distinct \\ 3) do
    by_domain =
      places
      |> Enum.flat_map(fn p ->
        url = fetch(p, :website)

        case registrable_domain(url) do
          nil -> []
          d -> [{d, {host_of(url), normalize_title(fetch(p, :title))}}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    by_domain
    |> Enum.filter(fn {domain, entries} ->
      hosts = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      titles = entries |> Enum.map(&elem(&1, 1)) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

      subdomain_fanout =
        length(hosts) >= min_distinct and Enum.any?(hosts, &(&1 != domain))

      # A chain may legitimately carry a couple of name variants (Arabic/Latin),
      # so require both a floor and a high distinct-to-places ratio.
      title_fanout =
        length(titles) >= min_distinct and
          length(titles) / max(length(entries), 1) >= 0.5

      subdomain_fanout or title_fanout
    end)
    |> MapSet.new(&elem(&1, 0))
  end

  # The key to use for a website: the full host on a platform domain, the
  # registrable domain otherwise.
  defp brand_domain(website, platforms) do
    case registrable_domain(website) do
      nil ->
        nil

      d ->
        if MapSet.member?(platforms, d) do
          h = host_of(website)
          if h && h != d, do: h, else: nil
        else
          d
        end
    end
  end

  defp host_of(nil), do: nil

  defp host_of(url) do
    url
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r{^[a-z]+://}, "")
    |> String.split(~r{[/?#]}, parts: 2)
    |> hd()
    |> String.split(":", parts: 2)
    |> hd()
    |> String.replace_prefix("www.", "")
    |> case do
      "" -> nil
      h -> h
    end
  end

  @doc """
  Explicit alias table for merges that normalization cannot reach — most often a
  brand listed in both scripts (`Hagouga` / `حجوجة`). Seeded by hand from the
  audit pass; an explicit table terminates where keyword heuristics do not.
  """
  @spec aliases() :: %{optional(key()) => key()}
  def aliases do
    %{
      # Same chain listed under a Latin and an Arabic name; trigram similarity is
      # zero across scripts, so these only merge by hand.
      "t:sale sucre" => "d:salesucre.com",
      "t:ساليه سوكريه" => "d:salesucre.com",
      "t:tbs the bakery shop" => "d:tbsfresh.com",
      "t:tbs" => "d:tbsfresh.com",
      "t:la poire cafe" => "d:lapoire.online",
      "t:la poire" => "d:lapoire.online",
      "t:لابوار" => "d:lapoire.online",
      "d:lapoire-group.com" => "d:lapoire.online",
      "t:كوجه koojeh" => "t:كوجه"
    }
  end

  defp alias_for(key), do: Map.get(aliases(), key, key)

  @doc "Registrable domain of a URL, or nil when absent, unparseable, or shared."
  @spec registrable_domain(String.t() | nil) :: String.t() | nil
  def registrable_domain(nil), do: nil
  def registrable_domain(""), do: nil

  def registrable_domain(url) when is_binary(url) do
    host =
      url
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r{^[a-z]+://}, "")
      |> String.split(~r{[/?#]}, parts: 2)
      |> hd()
      |> String.split(":", parts: 2)
      |> hd()
      |> String.replace_prefix("www.", "")

    cond do
      host == "" or not String.contains?(host, ".") -> nil
      Enum.any?(@subdomain_significant, &String.ends_with?(host, &1)) -> keep_if_allowed(host)
      true -> host |> registrable() |> keep_if_allowed()
    end
  end

  defp registrable(host) do
    labels = String.split(host, ".")

    case labels do
      [_ | _] = l when length(l) >= 3 ->
        last_two = l |> Enum.take(-2) |> Enum.join(".")
        if last_two in @two_level_suffixes, do: Enum.join(Enum.take(l, -3), "."), else: last_two

      l ->
        Enum.join(l, ".")
    end
  end

  defp keep_if_allowed(nil), do: nil

  defp keep_if_allowed(host) do
    if Enum.any?(@never_a_brand, &(host == &1 or String.ends_with?(host, "." <> &1))),
      do: nil,
      else: host
  end

  @doc "Saudi/Egyptian phone to bare MSISDN digits, or nil."
  @spec normalize_phone(String.t() | nil) :: String.t() | nil
  def normalize_phone(nil), do: nil

  def normalize_phone(raw) when is_binary(raw) do
    digits = raw |> arabic_digits() |> String.replace(~r/\D/, "")

    cond do
      digits == "" -> nil
      String.starts_with?(digits, "00") -> nil_if_short(String.slice(digits, 2..-1//1))
      String.starts_with?(digits, "966") -> nil_if_short(digits)
      String.starts_with?(digits, "20") and byte_size(digits) >= 11 -> nil_if_short(digits)
      String.starts_with?(digits, "05") -> "966" <> String.slice(digits, 1..-1//1)
      String.starts_with?(digits, "5") and byte_size(digits) == 9 -> "966" <> digits
      String.starts_with?(digits, "01") and byte_size(digits) == 10 -> "966" <> String.slice(digits, 1..-1//1)
      String.starts_with?(digits, "01") and byte_size(digits) == 11 -> "20" <> String.slice(digits, 1..-1//1)
      true -> nil_if_short(digits)
    end
  end

  defp nil_if_short(d) when byte_size(d) < 9, do: nil
  defp nil_if_short(d), do: d

  @doc """
  Fold a branch title down to a brand root.

  The conditional suffix split in step 5 is the important one: splitting on every
  hyphen destroys `Chick-fil-A` and `Baskin-Robbins`, so the tail is only dropped
  when it actually looks like a branch designator.
  """
  @spec normalize_title(String.t() | nil) :: String.t()
  def normalize_title(nil), do: ""

  def normalize_title(title) when is_binary(title) do
    raw = String.trim(title)

    out =
      raw
      |> arabic_digits()
      |> strip_marks()
      |> String.replace("ـ", "")
      |> fold_arabic()
      |> drop_branch_tail()
      |> String.replace(~r/\b(?:فرع|branch)\b.*$/iu, "")
      |> strip_affixes()
      |> String.replace(~r/[\p{P}\p{S}]/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.downcase()

    if String.length(out) < 2, do: String.downcase(raw), else: out
  end

  # A hyphen only separates a branch when it is *spaced*: "Dunkin - Hittin" splits,
  # "Baskin-Robbins" must not. Pipe and Arabic comma separate either way.
  @branch_sep ~r/\s+[-–—\/]\s+|\s*[|،]\s*/u

  defp drop_branch_tail(s) do
    case String.split(s, @branch_sep, parts: 2) do
      [head, tail] ->
        if branchy?(tail) and String.length(String.trim(head)) >= 2, do: head, else: s

      _ ->
        s
    end
  end

  defp branchy?(tail) do
    t = String.downcase(tail)

    Regex.match?(~r/فرع|branch|\d/u, t) or
      Enum.any?(districts(), &String.contains?(t, &1)) or
      Enum.any?(districts_en(), &String.contains?(t, &1))
  end

  defp strip_affixes(s) do
    s
    |> strip_leading_affixes()
    |> strip_districts()
    |> String.trim()
  end

  defp strip_leading_affixes(s) do
    Enum.reduce(@generic_affixes, s, fn a, acc ->
      String.replace(acc, ~r/^\s*#{Regex.escape(a)}\s+/iu, "")
    end)
  end

  defp strip_districts(s) do
    (districts() ++ districts_en())
    |> Enum.reduce(s, fn d, acc ->
      acc
      |> String.replace(~r/\s*حي\s+#{Regex.escape(d)}\s*$/u, " ")
      |> String.replace(~r/\s+#{Regex.escape(d)}\s*$/iu, " ")
    end)
  end

  defp districts, do: GmapsEx.Malqa.Districts.names_ar()
  defp districts_en, do: GmapsEx.Malqa.Districts.names_en()

  @doc "Modal raw title for a brand's member rows — a readable name, not the key."
  @spec display_name([map()]) :: String.t()
  def display_name([]), do: ""

  def display_name(places) do
    places
    |> Enum.map(&fetch(&1, :title))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.frequencies()
    |> Enum.max_by(fn {_t, n} -> n end, fn -> {"", 0} end)
    |> elem(0)
    |> case do
      "" -> places |> Enum.map(&fetch(&1, :title)) |> Enum.find("", &(&1 not in [nil, ""]))
      t -> t
    end
  end

  # ── text helpers ──────────────────────────────────────────────────────

  defp arabic_digits(s) do
    s
    |> String.replace(~r/[\x{0660}-\x{0669}]/u, fn d ->
      <<c::utf8>> = d
      <<c - 0x0660 + ?0>>
    end)
    |> String.replace(~r/[\x{06F0}-\x{06F9}]/u, fn d ->
      <<c::utf8>> = d
      <<c - 0x06F0 + ?0>>
    end)
  end

  # Arabic harakat/shadda/sukun, plus Latin accents via NFD.
  defp strip_marks(s) do
    s
    |> String.replace(
      ~r/[\x{0610}-\x{061A}\x{064B}-\x{065F}\x{0670}\x{06D6}-\x{06ED}]/u,
      ""
    )
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.normalize(:nfc)
  end

  defp fold_arabic(s) do
    s
    |> String.replace(~r/[أإآٱ]/u, "ا")
    |> String.replace("ة", "ه")
    |> String.replace("ى", "ي")
    |> String.replace("ؤ", "و")
    |> String.replace("ئ", "ي")
    |> String.replace("ی", "ي")
    |> String.replace("ک", "ك")
  end

  defp fetch(m, k) when is_map(m) do
    case Map.fetch(m, k) do
      {:ok, v} -> v
      :error -> Map.get(m, Atom.to_string(k))
    end
  end
end
