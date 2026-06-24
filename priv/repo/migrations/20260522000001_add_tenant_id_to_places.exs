defmodule GmapsEx.Repo.Migrations.AddTenantIdToPlaces do
  use Ecto.Migration

  def change do
    alter table(:places) do
      add :tenant_id, :text
    end

    # Composite unique on (tenant_id, data_id) so the same place can be scraped
    # for multiple tenants without collision. Existing unique on data_id stays
    # because tenant-less rows (tenant_id IS NULL) keep their global uniqueness.
    create unique_index(:places, [:tenant_id, :data_id],
             where: "tenant_id IS NOT NULL",
             name: :places_tenant_data_index
           )

    create index(:places, [:tenant_id], where: "tenant_id IS NOT NULL")
  end
end
