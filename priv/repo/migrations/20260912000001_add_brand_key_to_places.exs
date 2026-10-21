defmodule GmapsEx.Repo.Migrations.AddBrandKeyToPlaces do
  use Ecto.Migration

  @moduledoc """
  Derived brand/district columns for the Al Malqa white-space analysis.

  These are deliberately NOT declared in the `GmapsEx.Place` schema. `Places.upsert/1`
  uses `on_conflict: {:replace_all_except, [:id, :inserted_at]}`, which enumerates
  *schema* fields — declaring them would make every re-scrape reset them to NULL
  mid-run. Reads and writes go through raw SQL in `GmapsEx.Whitespace`.
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

    alter table(:places) do
      add(:brand_key, :text)
      add(:brand_name, :text)
      add(:district, :text)
    end

    create(index(:places, [:brand_key]))
    create(index(:places, [:district]))
    create(index(:places, [:input_id]))
  end

  def down do
    drop(index(:places, [:input_id]))
    drop(index(:places, [:district]))
    drop(index(:places, [:brand_key]))

    alter table(:places) do
      remove(:brand_key)
      remove(:brand_name)
      remove(:district)
    end
  end
end
