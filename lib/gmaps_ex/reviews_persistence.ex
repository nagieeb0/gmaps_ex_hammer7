defmodule GmapsEx.ReviewsPersistence do
  @moduledoc """
  Bulk-insert reviews for a given place. Idempotent — re-running the same scrape
  upserts on `(place_id, name, when)` and replaces all non-key columns.
  """

  import Ecto.Query

  alias GmapsEx.{Repo, Review}

  @doc """
  Insert (or upsert) a batch of review maps for `place_id`. Returns the count
  inserted/updated.
  """
  @spec bulk_upsert(Ecto.UUID.t(), [map()]) :: non_neg_integer()
  def bulk_upsert(place_id, reviews) when is_binary(place_id) and is_list(reviews) do
    now = DateTime.utc_now()

    entries =
      reviews
      |> Enum.filter(&valid?/1)
      |> Enum.map(fn r ->
        %{
          id: Ecto.UUID.generate(),
          place_id: place_id,
          name: Map.get(r, :name, ""),
          profile_picture: Map.get(r, :profile_picture),
          rating: Map.get(r, :rating, 0),
          description: Map.get(r, :description),
          when: Map.get(r, :when, ""),
          images: Map.get(r, :images, []),
          inserted_at: now,
          updated_at: now
        }
      end)

    case entries do
      [] ->
        0

      _ ->
        {count, _} =
          Repo.insert_all(
            Review,
            entries,
            on_conflict: {:replace_all_except, [:id, :inserted_at]},
            conflict_target: [:place_id, :name, :when]
          )

        count
    end
  end

  @doc "Count reviews persisted for a place."
  @spec count_for_place(Ecto.UUID.t()) :: non_neg_integer()
  def count_for_place(place_id) do
    Repo.aggregate(from(r in Review, where: r.place_id == ^place_id), :count)
  end

  defp valid?(%{name: n}) when is_binary(n) and n != "", do: true
  defp valid?(_), do: false
end
