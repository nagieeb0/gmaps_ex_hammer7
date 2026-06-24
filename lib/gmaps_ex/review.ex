defmodule GmapsEx.Review do
  @moduledoc """
  Ecto schema for a single user review. Mirrors the `Review` struct in
  `gmaps/entry.go:51-58`. One-to-many from `GmapsEx.Place`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GmapsEx.Place

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "reviews" do
    belongs_to(:place, Place)
    field(:name, :string)
    field(:profile_picture, :string)
    field(:rating, :integer)
    field(:description, :string)
    field(:when, :string)
    field(:images, {:array, :string}, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @castable ~w(place_id name profile_picture rating description when images)a

  def changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @castable)
    |> validate_required([:place_id, :name])
  end
end
