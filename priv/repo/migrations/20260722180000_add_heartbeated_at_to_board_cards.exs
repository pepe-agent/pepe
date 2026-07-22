defmodule Pepe.Repo.Migrations.AddHeartbeatedAtToBoardCards do
  use Ecto.Migration

  # A separate column from `claimed_at`: `Pepe.Board.heartbeat/2` used to bump `claimed_at`
  # itself, but that column doubles as the claim's identity token for
  # `Pepe.Board.block_if_still_running/3`'s ABA guard (the scheduler captures it at dispatch
  # time and compares against it when the worker dies) - a heartbeat during a long run moved
  # that token out from under the scheduler's own safety net. Liveness now lives here instead.
  def change do
    alter table(:board_cards) do
      add :heartbeated_at, :integer
    end
  end
end
