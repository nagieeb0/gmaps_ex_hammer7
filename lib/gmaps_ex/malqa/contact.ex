defmodule GmapsEx.Malqa.Contact do
  @moduledoc """
  Turn a scraped phone/website into something the owner can actually act on.

  The important part is the mobile/landline distinction. The existing `leads.html`
  builds WhatsApp links in JS by blindly prefixing `966` to whatever it was given,
  which produces a dead link for every Riyadh landline. Elixir can tell the
  difference, so the resolved link is computed here and shipped ready-made.
  """

  @type kind :: :mobile | :landline
  @type channel :: :whatsapp | :phone | :email | :instagram | :visit | :none

  @doc """
  Normalize to a bare MSISDN and classify it.

  Saudi mobiles are `5XXXXXXXX` after the country code; anything else on a Saudi
  number is a landline. Egyptian mobiles are `1XXXXXXXXX`.
  """
  @spec normalize(String.t() | nil) :: {:ok, String.t(), kind()} | :error
  def normalize(nil), do: :error

  def normalize(raw) when is_binary(raw) do
    digits =
      raw
      |> arabic_digits()
      |> String.replace(~r/\D/, "")

    msisdn =
      cond do
        digits == "" -> nil
        String.starts_with?(digits, "00") -> String.slice(digits, 2..-1//1)
        String.starts_with?(digits, "966") -> digits
        String.starts_with?(digits, "20") and byte_size(digits) >= 12 -> digits
        String.starts_with?(digits, "05") and byte_size(digits) == 10 -> "966" <> String.slice(digits, 1..-1//1)
        String.starts_with?(digits, "5") and byte_size(digits) == 9 -> "966" <> digits
        String.starts_with?(digits, "01") and byte_size(digits) == 10 -> "966" <> String.slice(digits, 1..-1//1)
        String.starts_with?(digits, "01") and byte_size(digits) == 11 -> "20" <> String.slice(digits, 1..-1//1)
        String.starts_with?(digits, "9200") -> digits
        byte_size(digits) >= 9 -> digits
        true -> nil
      end

    case msisdn do
      nil -> :error
      m -> {:ok, m, kind(m)}
    end
  end

  defp kind("966" <> rest) do
    cond do
      String.starts_with?(rest, "5") -> :mobile
      true -> :landline
    end
  end

  defp kind("20" <> rest) do
    if String.starts_with?(rest, "1"), do: :mobile, else: :landline
  end

  # 920/800 unified numbers are call centres, never WhatsApp.
  defp kind("920" <> _), do: :landline
  defp kind("800" <> _), do: :landline
  defp kind(_), do: :landline

  @doc "WhatsApp link, or nil when the number cannot receive WhatsApp."
  @spec wa_link(String.t() | nil) :: String.t() | nil
  def wa_link(raw) do
    case normalize(raw) do
      {:ok, msisdn, :mobile} -> "https://wa.me/" <> msisdn
      _ -> nil
    end
  end

  @doc "Display form of a phone number: `+966 5X XXX XXXX`."
  @spec display(String.t() | nil) :: String.t() | nil
  def display(raw) do
    case normalize(raw) do
      {:ok, m, _} -> "+" <> m
      :error -> nil
    end
  end

  @doc """
  Instagram handle when the "website" is really an Instagram profile.

  Common in Riyadh F&B — a lot of places list their Instagram as the website, and
  treating that as a brand domain would be wrong twice over.
  """
  @spec instagram_handle(String.t() | nil) :: String.t() | nil
  def instagram_handle(nil), do: nil

  def instagram_handle(url) when is_binary(url) do
    case Regex.run(~r{instagram\.com/([A-Za-z0-9_.]+)}i, url) do
      [_, handle] when handle not in ["p", "reel", "explore", "accounts"] -> handle
      _ -> nil
    end
  end

  @doc "A real website — nil when the URL is just a social or aggregator link."
  @spec real_website(String.t() | nil) :: String.t() | nil
  def real_website(nil), do: nil

  def real_website(url) do
    if GmapsEx.Brand.registrable_domain(url), do: url, else: nil
  end

  @doc """
  Pick the channel to open with, and say why in Arabic.

  Ordered by what actually gets answered in this market, not by what is tidiest:
  a mobile on a Maps listing in Riyadh is usually the owner's own WhatsApp.
  """
  @spec best_channel(map(), atom()) :: {channel(), String.t()}
  def best_channel(row, track) do
    phone = row[:phone]
    wa = wa_link(phone)
    email = first_email(row[:emails])
    ig = instagram_handle(row[:website])
    site = real_website(row[:website])

    cond do
      track == :a2 and wa -> {:whatsapp, "واتساب — المشغّل يرد بنفسه غالباً"}
      track == :b and ig -> {:instagram, "رسالة إنستغرام — أسرع قناة للبراندات المصرية"}
      email && brandy_email?(email) -> {:email, "إيميل الشركة — #{email}"}
      wa -> {:whatsapp, "واتساب على رقم الفرع"}
      ig -> {:instagram, "إنستغرام — لا يوجد رقم جوال"}
      email -> {:email, email}
      phone -> {:phone, "اتصال — الرقم أرضي/موحّد ولا يقبل واتساب"}
      site -> {:phone, "نموذج التواصل في الموقع"}
      true -> {:visit, "زيارة ميدانية — لا توجد بيانات تواصل"}
    end
  end

  defp brandy_email?(email) do
    not Enum.any?(
      ~w(gmail.com hotmail.com yahoo.com outlook.com icloud.com),
      &String.ends_with?(String.downcase(email), &1)
    )
  end

  defp first_email(nil), do: nil
  defp first_email([]), do: nil
  defp first_email([e | _]), do: e
  defp first_email(e) when is_binary(e), do: e

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
end
