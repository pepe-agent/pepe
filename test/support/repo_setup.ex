defmodule Pepe.RepoSetup do
  @moduledoc """
  Starts `Pepe.Repo` for a single test, pointed at that test's own `PEPE_HOME`.

  Not `Ecto.Adapters.SQL.Sandbox`: every test in this codebase already isolates
  itself with a fresh temp `PEPE_HOME` per test (`async: false`), the same
  convention `Pepe.Store` (Mnesia) and `config.json` itself already rely on -
  Sandbox's checkout-per-connection model doesn't fit a repo whose *database path*
  changes per test, only its transaction scope. `start_supervised!/1` mirrors how
  several tests already start a scoped `Task.Supervisor`/`GenServer` per test.

  Call this from `setup`, after `System.put_env("PEPE_HOME", home)` - `Pepe.Repo`
  resolves its database path from `Pepe.Config.home()` at `start_link` time (see
  `Pepe.Repo.init/2`), so the order matters.
  """

  @doc "Start Pepe.Repo for this test and run schema migrations against it."
  def start! do
    # config/test.exs deliberately carries no Repo block (Pepe.Repo is never
    # auto-started under :test), so without an explicit pool_size here Ecto falls back
    # to its own multi-connection default - several connections all opening the same
    # single-writer SQLite file at once produces real, if usually-survivable,
    # "database is locked" contention. One connection is also all a single test needs.
    ExUnit.Callbacks.start_supervised!({Pepe.Repo, pool_size: 1, journal_mode: :wal, busy_timeout: 5_000})

    Ecto.Migrator.run(Pepe.Repo, Application.app_dir(:pepe, "priv/repo/migrations"), :up,
      all: true,
      log: false
    )

    :ok
  end
end
