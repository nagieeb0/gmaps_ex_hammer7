defmodule GmapsEx.PlacesTest do
  use GmapsEx.DataCase, async: true

  alias GmapsEx.{Factory, Places, Repo}

  describe "upsert/1" do
    test "inserts a new place" do
      attrs = %{
        data_id: "0xabc:0xdef",
        title: "New Spot",
        review_count: 5,
        review_rating: 4.2
      }

      assert {:ok, place} = Places.upsert(attrs)
      assert place.data_id == "0xabc:0xdef"
      assert place.title == "New Spot"
    end

    test "upserts on data_id when a row already exists with the same data_id" do
      place = Factory.place(%{data_id: "0xstable:0xid", title: "Original", review_count: 10})

      {:ok, updated} =
        Places.upsert(%{
          data_id: "0xstable:0xid",
          title: "Enriched",
          review_count: 100,
          review_rating: 4.8
        })

      assert updated.id == place.id
      assert updated.title == "Enriched"
      assert updated.review_count == 100

      # Single row in the table
      assert Repo.aggregate(GmapsEx.Place, :count) == 1
    end

    test "upserts on cid when data_id is missing but cid exists" do
      Factory.place(%{data_id: nil, cid: "cid-123", title: "By CID"})

      {:ok, updated} =
        Places.upsert(%{cid: "cid-123", title: "Updated By CID", review_count: 50})

      assert updated.title == "Updated By CID"
      assert Repo.aggregate(GmapsEx.Place, :count) == 1
    end

    test "rejects insert without a title" do
      assert {:error, changeset} = Places.upsert(%{data_id: "0xnopath:0x1"})
      assert changeset.errors[:title]
    end
  end

  describe "get_by_cid/1" do
    test "returns the place" do
      Factory.place(%{cid: "lookup-cid", title: "Findable"})
      assert %{title: "Findable"} = Places.get_by_cid("lookup-cid")
    end

    test "returns nil when no match" do
      assert is_nil(Places.get_by_cid("missing"))
    end
  end
end
