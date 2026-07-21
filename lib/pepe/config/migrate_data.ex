defmodule Pepe.Config.MigrateData do
  @moduledoc """
  Runs every subsystem's one-time `Pepe.Repo` import in one operator command
  (`mix pepe config migrate-data`), instead of one command per subsystem
  (`migrate-commitments` already shipped standalone before this existed, and stays that
  way - not folded in here).

  Each subsystem's own migration module is independent and already safe to run more than
  once (see e.g. `Pepe.Watches.Migration`'s moduledoc) - one subsystem failing or having
  nothing to do never stops another from running.
  """

  @doc """
  Run every subsystem's migration; returns one `{subsystem, report}` pair per subsystem,
  in a fixed order (not a bare map - a map's enumeration order isn't guaranteed, and the
  CLI output should be stable run to run).
  """
  @spec run() :: [{atom(), term()}]
  def run do
    [
      config_journal: safe_run(&Pepe.Config.Journal.Migration.run/0),
      watches: safe_run(&Pepe.Watches.Migration.run/0),
      traces: safe_run(&Pepe.Trace.Migration.run/0),
      boards: safe_run(&Pepe.Board.Migration.run/0)
    ]
  end

  # A migration module reporting failure per-entry is the normal path (handled by its own
  # report shape); this only guards against something unexpected blowing up mid-import -
  # legacy, possibly hand-edited data is exactly where that can happen, and one subsystem
  # crashing must never take the others down with it.
  defp safe_run(fun) do
    fun.()
  rescue
    e -> {:error, Exception.message(e)}
  end
end
