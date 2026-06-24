defmodule GmapsEx.Place do
  @moduledoc """
  Ecto schema for a scraped place. Mirrors the `Entry` struct in
  `google-maps-scraper-main/gmaps/entry.go:60-98`.

  Two-mode use:

    * As a plain struct via `%GmapsEx.Place{}` — used by the parsers, which produce these
      before the persistence layer is involved.
    * As an Ecto schema — used by the upsert path against Postgres.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @typedoc "A scraped place. Either a transient parser output or a persisted Ecto record."
  @type t :: %__MODULE__{}

  schema "places" do
    field(:input_id, :string)
    field(:link, :string)
    field(:cid, :string)
    field(:data_id, :string)
    field(:place_id, :string)
    field(:tenant_id, :string)

    field(:title, :string)
    field(:category, :string)
    field(:categories, {:array, :string}, default: [])
    field(:address, :string)

    field(:open_hours, :map, default: %{})
    field(:popular_times, :map, default: %{})

    field(:website, :string)
    field(:phone, :string)
    field(:plus_code, :string)

    field(:review_count, :integer, default: 0)
    field(:review_rating, :float)
    field(:reviews_per_rating, :map, default: %{})

    field(:latitude, :float)
    field(:longitude, :float)

    field(:status, :string)
    field(:description, :string)
    field(:reviews_link, :string)
    field(:thumbnail, :string)
    field(:timezone, :string)
    field(:price_range, :string)

    field(:images, {:array, :map}, default: [])
    field(:reservations, {:array, :map}, default: [])
    field(:order_online, {:array, :map}, default: [])
    field(:menu, :map, default: %{})
    field(:owner, :map, default: %{})
    field(:complete_address, :map, default: %{})
    field(:about, {:array, :map}, default: [])

    field(:emails, {:array, :string}, default: [])
    field(:extra, :map, default: %{})

    has_many(:reviews, GmapsEx.Review, foreign_key: :place_id)

    timestamps(type: :utc_datetime_usec)
  end

  @required_for_upsert ~w(title)a
  @castable_fields ~w(
    input_id link cid data_id place_id tenant_id
    title category categories address
    open_hours popular_times
    website phone plus_code
    review_count review_rating reviews_per_rating
    latitude longitude
    status description reviews_link thumbnail timezone price_range
    images reservations order_online menu owner complete_address about
    emails extra
  )a

  @doc """
  Builds a changeset for upserting a place. Upserts conflict on `cid` (Google's stable
  place ID) — falls back to `place_id` if cid is absent, and finally to `data_id`.
  """
  def upsert_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @castable_fields)
    |> validate_required(@required_for_upsert)
    |> unique_constraint(:data_id, name: :places_data_id_index)
    |> unique_constraint(:cid, name: :places_cid_index)
    |> unique_constraint(:place_id, name: :places_place_id_index)
  end

  @doc """
  Convert a parser-produced plain struct to a flat map suitable for cast.

  Drops Ecto metadata, the primary key, timestamps, and the `:reviews`
  association — the latter is `%Ecto.Association.NotLoaded{}` by default and
  would crash JSON encoders downstream.
  """
  def to_attrs(%__MODULE__{} = p) do
    p
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :reviews])
  end
end
