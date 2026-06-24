defmodule GmapsEx.Repo.Migrations.CreateReviews do
  use Ecto.Migration

  def change do
    create table(:reviews, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :place_id, references(:places, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :profile_picture, :text
      add :rating, :integer
      add :description, :text
      add :when, :text
      add :images, {:array, :text}, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create index(:reviews, [:place_id])
  end
end
