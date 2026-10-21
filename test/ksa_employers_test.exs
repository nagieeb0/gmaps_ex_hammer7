defmodule Mix.Tasks.Gmaps.KsaEmployersTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Gmaps.KsaEmployers, as: T

  defp place(attrs) do
    struct(
      GmapsEx.Place,
      Map.merge(
        %{
          input_id: "ksa-employers:jeddah:central:fm",
          title: "Acme FM",
          category: "facility management company",
          categories: [],
          emails: [],
          website: nil,
          phone: nil,
          review_count: 0,
          review_rating: nil,
          status: nil
        },
        Map.new(attrs)
      )
    )
  end

  test "parses city and sector back out of input_id" do
    p = place(input_id: "ksa-employers:eastern:jubail:industrial")
    assert T.city(p) == "eastern"
    assert T.sector(p) == "industrial"

    assert T.city(place(input_id: "riyadh-healthcare:north:dental")) == "unknown"
  end

  test "an email outranks a website outranks a phone, all else equal" do
    email = T.score(place(emails: ["hr@acme.sa"]))
    site = T.score(place(website: "https://acme.sa"))
    phone = T.score(place(phone: "+966500000000"))
    none = T.score(place([]))

    assert email > site and site > phone and phone > none
  end

  test "Jeddah outranks Riyadh outranks the Eastern Province" do
    for [a, b] <- Enum.chunk_every(~w(jeddah riyadh eastern), 2, 1, :discard) do
      assert T.score(place(input_id: "ksa-employers:#{a}:central:fm")) >
               T.score(place(input_id: "ksa-employers:#{b}:central:fm"))
    end
  end

  test "FM/O&M outranks contracting outranks recruitment" do
    for [a, b] <- Enum.chunk_every(~w(fm contracting recruitment), 2, 1, :discard) do
      assert T.score(place(input_id: "ksa-employers:jeddah:central:#{a}")) >
               T.score(place(input_id: "ksa-employers:jeddah:central:#{b}"))
    end
  end

  test "closed places and rejected categories score zero" do
    assert T.score(place(emails: ["a@b.sa"], status: "Permanently closed")) == 0
    assert T.score(place(emails: ["a@b.sa"], category: "Restaurant")) == 0
    assert T.score(place(emails: ["a@b.sa"], category: "مطعم")) == 0
    # A blank category must NOT be treated as a rejection.
    assert T.score(place(emails: ["a@b.sa"], category: nil)) > 0
  end

  describe "relevance" do
    test "classifies the categories that polluted the first run" do
      # These all arrived via the om/fm queries and took full sector fit.
      for c <- [
            "تصليح سيارات",
            "Plant nursery",
            "Swimming pool contractor",
            "Call center",
            "Appliance repair service",
            "Auto repair shop"
          ] do
        assert T.relevance(place(category: c)) == "reject", "expected reject: #{c}"
      end

      for c <- [
            "Construction company",
            "HVAC contractor",
            "مستشفى",
            "مصنع",
            "Property maintenance",
            "Oil refinery",
            "Desalination plant",
            "Corporate office",
            "Human resource consulting",
            "Elevator service"
          ] do
        assert T.relevance(place(category: c)) == "core", "expected core: #{c}"
      end

      for c <- ["Industrial equipment supplier", "متجر تكييف الهواء", "عيادة طبية"] do
        assert T.relevance(place(category: c)) == "weak", "expected weak: #{c}"
      end

      assert T.relevance(place(category: nil)) == "unverified"
      assert T.relevance(place(category: "Mystery Business Type")) == "unverified"
    end

    test "reject beats core when a place carries both signals" do
      # A car workshop that also lists itself under "صيانة" must still be out.
      p = place(category: "تصليح سيارات", categories: ["تصليح سيارات", "خدمة صيانة"])
      assert T.relevance(p) == "reject"
      assert T.score(p) == 0
    end

    test "relevance discounts sector fit but not reachability" do
      core = place(category: "Construction company", emails: ["a@b.sa"])
      weak = place(category: "Industrial equipment supplier", emails: ["a@b.sa"])
      unver = place(category: "Mystery Business Type", emails: ["a@b.sa"])

      assert T.score(core) > T.score(unver)
      assert T.score(unver) > T.score(weak)
      # The email is still worth its full 30 even at the weak tier.
      assert T.score(weak) > T.score(place(category: "Industrial equipment supplier"))
    end
  end

  test "size proxy is log-scaled and capped at 20" do
    big = T.score(place(review_count: 5_000))
    mid = T.score(place(review_count: 100))
    small = T.score(place(review_count: 3))

    assert big > mid and mid > small
    assert big - mid < mid - small, "log scale: the top end must compress"
    assert big <= 100
  end

  test "reputation only counts once there are enough reviews" do
    # 4 reviews: rating ignored. 5 reviews: rating counts.
    assert T.score(place(review_rating: 5.0, review_count: 4)) ==
             T.score(place(review_rating: nil, review_count: 4))

    assert T.score(place(review_rating: 5.0, review_count: 5)) >
             T.score(place(review_rating: 2.0, review_count: 5))
  end

  test "grades are monotonic and bounded" do
    assert T.grade(100) == "A+"
    assert T.grade(75) == "A+"
    assert T.grade(74) == "A"
    assert T.grade(62) == "A"
    assert T.grade(61) == "B"
    assert T.grade(48) == "B"
    assert T.grade(0) == "C"
  end

  test "a perfect Jeddah FM lead lands in A+, a bare Yanbu recruiter does not" do
    best =
      place(
        input_id: "ksa-employers:jeddah:central:fm",
        emails: ["careers@acme.sa"],
        review_count: 800,
        review_rating: 4.6
      )

    worst = place(input_id: "ksa-employers:yanbu:industrial:recruitment")

    assert T.grade(T.score(best)) == "A+"
    assert T.grade(T.score(worst)) == "C"
  end
end
