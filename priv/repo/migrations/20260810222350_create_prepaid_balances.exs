defmodule Pepe.Repo.Migrations.CreatePrepaidBalances do
  use Ecto.Migration

  def change do
    # A project with no row here is exactly as it was before this existed: only the
    # monthly cap (project_budget/1) gates it, no prepaid balance in the picture. A row
    # only ever appears once something credits it (Pepe.Usage.Prepaid.credit/2) - this
    # is opt-in per project, not a mode flag anyone has to turn on separately.
    #
    # `balance`/`settled_through_id` are a checkpoint, not a live number: the real
    # balance is always `balance - billable spend recorded after settled_through_id`
    # (usage_entries, priced the same way month_to_date/1 already is), computed on read.
    # credit/2 settles the checkpoint (folds spend since the last one in) before adding
    # funds, so the stored number never silently drifts from what the ledger says was
    # spent. A usage_entries *id*, not a timestamp: entries only carry second
    # resolution, so two events landing in the same wall-clock second (a routine thing
    # under real load, not an edge case) would be genuinely ambiguous to order by time -
    # the auto-increment id is the one thing that's never ambiguous.
    create table(:prepaid_balances, primary_key: false) do
      add :project, :string, primary_key: true
      add :balance, :float, null: false, default: 0.0
      add :settled_through_id, :integer, null: false, default: 0
    end
  end
end
