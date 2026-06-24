defmodule GmapsEx.Repo.Migrations.AddReviewsDedupeIndex do
  use Ecto.Migration

  def change do
    # Without a stable Google review ID, dedupe by (place, author name, date).
    # Collisions (same author + same day + same place) are rare; if they occur
    # we keep the newer one (upsert on conflict).
    create unique_index(:reviews, [:place_id, :name, :when],
             name: :reviews_place_author_date_index
           )
  end
end
