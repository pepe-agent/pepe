defmodule Pepe.Drafts do
  @moduledoc """
  Drafts for the dashboard's edit forms.

  A form that saves straight to the config makes every keystroke live and every abandoned edit
  a decision. A draft separates the two: the form's state is stored as the operator changes it
  (so leaving the page, or the browser dying, loses nothing) and only an explicit Save writes
  it to the real definition, at which point the draft is deleted. The next change starts a new
  draft.

  A draft is addressed by `kind` (which screen: `"agent"`, `"model"`, ...) and `key` (which
  record, or `"new"` for one that does not exist yet). There is at most one per pair. `data` is
  whatever map the screen wants back; it round-trips through JSON, so keys come back as
  strings and the screen is responsible for turning them into what it needs.

  Operational data that grows with use, so it lives in `Pepe.Repo` (SQLite), not in
  `config.json`: a draft is not a definition until it is saved.
  """

  import Ecto.Query

  alias Pepe.Drafts.Draft
  alias Pepe.Repo

  @doc "The draft for this record as `%{data: map, updated_at: unix_seconds}`, or `nil`."
  @spec get(String.t(), String.t()) :: %{data: map(), updated_at: integer()} | nil
  def get(kind, key) do
    case Repo.get_by(Draft, kind: kind, key: key) do
      nil -> nil
      %Draft{data: data, updated_at: at} -> %{data: data, updated_at: at}
    end
  end

  @doc "Store (or replace) the draft for this record."
  @spec put(String.t(), String.t(), map()) :: :ok
  def put(kind, key, data) when is_map(data) do
    now = System.os_time(:second)

    Repo.insert!(
      %Draft{kind: kind, key: key, data: data, updated_at: now},
      on_conflict: {:replace, [:data, :updated_at]},
      conflict_target: [:kind, :key]
    )

    :ok
  end

  @doc "Drop the draft for this record (it was saved, or thrown away). A no-op when there is none."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(kind, key) do
    Repo.delete_all(from(d in Draft, where: d.kind == ^kind and d.key == ^key))
    :ok
  end

  @doc "The keys of every draft of this kind, so a list can mark the records that have one."
  @spec keys(String.t()) :: [String.t()]
  def keys(kind), do: Repo.all(from(d in Draft, where: d.kind == ^kind, select: d.key))
end
