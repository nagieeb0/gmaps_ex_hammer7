defmodule GmapsEx.Places do
  @moduledoc """
  Persistence context for `GmapsEx.Place`. The single point through which the
  workers and Broadway batchers write to Postgres.
  """

  import Ecto.Query, only: [from: 2]

  alias GmapsEx.{Place, Repo}

  @doc """
  Upsert one place. Conflict resolution is on `cid` first (Google's stable place ID),
  then `place_id`. Returns `{:ok, %Place{}}` or `{:error, changeset}`.
  """
  @spec upsert(map()) :: {:ok, Place.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) when is_map(attrs) do
    # data_id is the stable identifier present in BOTH search and place-detail
    # responses, so it's the most reliable conflict target. cid/place_id only
    # appear after enrichment, so they aren't useful as conflict targets across
    # the search → enrich flow.
    conflict_target =
      cond do
        Map.get(attrs, :data_id) not in [nil, ""] -> :data_id
        Map.get(attrs, :cid) not in [nil, ""] -> :cid
        Map.get(attrs, :place_id) not in [nil, ""] -> :place_id
        true -> nil
      end

    opts =
      case conflict_target do
        nil ->
          [returning: true]

        target ->
          [
            on_conflict: {:replace_all_except, [:id, :inserted_at]},
            conflict_target: target,
            returning: true
          ]
      end

    attrs
    |> Place.upsert_changeset()
    |> Repo.insert(opts)
  end

  @doc "Bulk upsert. Each item is the attrs map (as produced by `Place.to_attrs/1`)."
  @spec upsert_all([map()]) :: {non_neg_integer(), nil | [Place.t()]}
  def upsert_all(attrs_list) when is_list(attrs_list) do
    now = DateTime.utc_now()

    entries =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    Repo.insert_all(
      Place,
      entries,
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :cid
    )
  end

  def get_by_cid(cid), do: Repo.one(from(p in Place, where: p.cid == ^cid))
end
