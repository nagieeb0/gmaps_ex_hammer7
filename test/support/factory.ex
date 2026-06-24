defmodule GmapsEx.Factory do
  @moduledoc """
  Test fixtures. Keep small — most tests should build only what they need.
  """

  alias GmapsEx.{Place, Repo}

  def place(attrs \\ %{}) do
    defaults = %{
      data_id: "0x#{random_hex(16)}:0x#{random_hex(16)}",
      title: "Test Coffee Shop",
      review_rating: 4.5,
      review_count: 100,
      latitude: 37.7749,
      longitude: -122.4194,
      address: "1 Test St, San Francisco, CA",
      phone: "+1 415-555-0100",
      website: "https://example.com",
      categories: ["Coffee shop"]
    }

    {:ok, place} =
      defaults
      |> Map.merge(attrs)
      |> Place.upsert_changeset()
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: :data_id,
        returning: true
      )

    place
  end

  defp random_hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
