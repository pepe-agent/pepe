defmodule Pepe.Board.Migration do
  @moduledoc """
  One-time, operator-run import of boards and their cards from their old home
  (`config.json`'s `"boards"` and `"board_cards"` sections) into `Pepe.Repo` - see
  `Pepe.Config.Board`'s moduledoc for why they moved. Not run automatically - see
  `Pepe.Commitments.Migration`'s moduledoc for why.

  Boards import before cards - the `board_cards.board` foreign key needs its board row to
  already exist. Idempotent and crash-safe, same shape as
  `Pepe.Commitments.Migration.run/0`: every row is inserted with `on_conflict: :nothing`,
  so an already-migrated id is silently skipped. Both `"boards"` and `"board_cards"` are
  removed from `config.json` together, only once *every* row of *both* sections has been
  inserted (or was already present) successfully - a partial success (e.g. every board
  imported but a card failed) leaves both keys in place, so a re-run always sees the
  complete picture rather than importing boards twice against orphaned card data.
  """

  alias Pepe.Config
  alias Pepe.Config.Board
  alias Pepe.Config.BoardCard
  alias Pepe.Repo

  @type report :: %{imported: non_neg_integer(), already_present: non_neg_integer(), failed: [{String.t(), term()}]}

  @doc """
  Import every board, then every card, still in config.json's legacy sections. Removes
  both keys once everything has succeeded; leaves them in place, and reports which ids
  failed and why, otherwise.
  """
  @spec run() :: report()
  def run do
    raw_boards = Config.load() |> Map.get("boards", %{})
    raw_cards = Config.load() |> Map.get("board_cards", %{})

    board_report = import_all(raw_boards, Board, &Board.from_map/1)
    card_report = import_all(raw_cards, BoardCard, &BoardCard.from_map/1)

    report = %{
      imported: board_report.imported + card_report.imported,
      already_present: board_report.already_present + card_report.already_present,
      failed: board_report.failed ++ card_report.failed
    }

    if report.failed == [] and (map_size(raw_boards) > 0 or map_size(raw_cards) > 0) do
      Config.update(fn config -> config |> Map.delete("boards") |> Map.delete("board_cards") end)
    end

    report
  end

  defp import_all(raw, schema, from_map) do
    {oks, fails} =
      raw
      |> Enum.map(fn {id, entry} -> {id, import_entry(id, entry, schema, from_map)} end)
      |> Enum.split_with(fn {_id, result} -> match?({:ok, _}, result) end)

    %{
      imported:
        Enum.count(oks, fn
          {_id, {:ok, :inserted}} -> true
          _ -> false
        end),
      already_present:
        Enum.count(oks, fn
          {_id, {:ok, :already_present}} -> true
          _ -> false
        end),
      failed: Enum.map(fails, fn {id, {:error, reason}} -> {id, reason} end)
    }
  end

  # A legacy entry's value should always be a map (that's the only shape anything ever
  # wrote), but this reads a file an operator could have hand-edited - fail this one entry
  # into `report.failed`, not a crash that takes the whole import down with it.
  defp import_entry(_id, entry, _schema, _from_map) when not is_map(entry), do: {:error, {:not_a_map, entry}}

  defp import_entry(id, entry, schema, from_map) do
    changeset = from_map.(Map.put(entry, "id", id))

    if changeset.valid? do
      row = changeset |> Ecto.Changeset.apply_changes() |> Map.from_struct() |> Map.drop([:__meta__])

      case Repo.insert_all(schema, [row], on_conflict: :nothing) do
        {1, _} -> {:ok, :inserted}
        {0, _} -> {:ok, :already_present}
      end
    else
      {:error, changeset.errors}
    end
  end
end
