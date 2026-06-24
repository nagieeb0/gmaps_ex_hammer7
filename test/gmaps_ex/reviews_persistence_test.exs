defmodule GmapsEx.ReviewsPersistenceTest do
  use GmapsEx.DataCase, async: true

  alias GmapsEx.{Factory, Review, ReviewsPersistence}

  test "inserts new reviews" do
    place = Factory.place()

    reviews = [
      %{name: "Alice", rating: 5, description: "Great", when: "2025-09-01", images: []},
      %{name: "Bob", rating: 3, description: "Okay", when: "2025-09-02", images: []}
    ]

    assert ReviewsPersistence.bulk_upsert(place.id, reviews) == 2
    assert Repo.aggregate(Review, :count) == 2
    assert ReviewsPersistence.count_for_place(place.id) == 2
  end

  test "upserts on (place_id, name, when) — same author + same day stays one row" do
    place = Factory.place()

    first = [%{name: "Alice", rating: 5, description: "First", when: "2025-09-01"}]
    second = [%{name: "Alice", rating: 4, description: "Updated", when: "2025-09-01"}]

    assert ReviewsPersistence.bulk_upsert(place.id, first) == 1
    assert ReviewsPersistence.bulk_upsert(place.id, second) == 1

    assert ReviewsPersistence.count_for_place(place.id) == 1
    [r] = Repo.all(Review)
    assert r.description == "Updated"
    assert r.rating == 4
  end

  test "skips reviews without a name" do
    place = Factory.place()
    assert ReviewsPersistence.bulk_upsert(place.id, [%{rating: 5}]) == 0
    assert ReviewsPersistence.count_for_place(place.id) == 0
  end

  test "handles empty list" do
    place = Factory.place()
    assert ReviewsPersistence.bulk_upsert(place.id, []) == 0
  end
end
