defmodule GmapsEx.Repo.Migrations.CreatePlaces do
  use Ecto.Migration

  def change do
    create table(:places, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :input_id, :text
      add :link, :text
      add :cid, :text
      add :data_id, :text
      add :place_id, :text

      add :title, :text, null: false
      add :category, :text
      add :categories, {:array, :text}, default: []
      add :address, :text

      add :open_hours, :map, default: %{}
      add :popular_times, :map, default: %{}

      add :website, :text
      add :phone, :text
      add :plus_code, :text

      add :review_count, :integer, default: 0
      add :review_rating, :float
      add :reviews_per_rating, :map, default: %{}

      add :latitude, :float
      add :longitude, :float

      add :status, :text
      add :description, :text
      add :reviews_link, :text
      add :thumbnail, :text
      add :timezone, :text
      add :price_range, :text

      add :images, {:array, :map}, default: []
      add :reservations, {:array, :map}, default: []
      add :order_online, {:array, :map}, default: []
      add :menu, :map, default: %{}
      add :owner, :map, default: %{}
      add :complete_address, :map, default: %{}
      add :about, {:array, :map}, default: []

      add :emails, {:array, :text}, default: []
      add :extra, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:places, [:cid])
    create unique_index(:places, [:place_id])
    create unique_index(:places, [:data_id])
    create index(:places, [:latitude, :longitude])
  end
end
