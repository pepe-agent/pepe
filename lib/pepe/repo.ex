defmodule Pepe.Repo do
  @moduledoc """
  The operational-data store: commitments, the config journal, watches, traces, boards,
  and usage - not `config.json`, which stays a plain file for definitions (agents, models,
  channels) that don't grow with usage. Existing on-disk/config.json data for any of these
  moves over via an explicit, operator-run `mix pepe config migrate-commitments` (just
  commitments) or `mix pepe config migrate-data` (everything else), never automatically.

  A single SQLite file under `PEPE_HOME`, mirroring where `Pepe.Store` (Mnesia)
  already puts its own data (`Pepe.Store.start_mnesia/0`).
  """
  use Ecto.Repo,
    otp_app: :pepe,
    adapter: Ecto.Adapters.SQLite3

  # Computed fresh at every start_link, never at compile/config time: PEPE_HOME can
  # change after this module is compiled (a `mix pepe` one-shot resolves the final
  # home before booting the app; every test sets it per-test, long before Repo starts
  # for that test). Reading Config.home() here, not baking a path into config.exs,
  # is what makes both of those work without any special-casing.
  @impl true
  def init(_type, config) do
    path = Path.join([Pepe.Config.home(), "data", "pepe.db"])
    File.mkdir_p!(Path.dirname(path))
    {:ok, Keyword.put(config, :database, path)}
  end

  @doc """
  Start this repo (and run its schema migrations) if it isn't already running -
  idempotent, safe to call from anywhere that's about to touch it.

  `Pepe.Repo` is an unconditional child under a real app boot (`Pepe.Application`),
  but several `mix pepe` commands (`agent`/`project` remove/rename, `extract`, `watch`,
  `board`, `usage`, `traces`, ...) dispatch through `with_config`, which never boots the
  app at all - config.json-only commands that now also touch operational data via
  `Pepe.Config` and friends. Mirrors `Pepe.Store`'s own lazy Mnesia bootstrap for exactly
  the same reason: some callers have no supervision tree to have started it for them.

  Deliberately not "just boot the full app instead": `with_config` skips
  `Pepe.Application.start/2` on purpose, to keep a one-shot CLI command fast (no Phoenix
  endpoint, no gateways, no schedulers) - this starts only the one thing that path is
  actually missing.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    # `with_config`-only commands never start the :ecto_sql/:ecto/:db_connection/:exqlite
    # applications at all (with_config only starts :jason) - Ecto.Repo.Registry, which
    # start_link/1 below needs, lives in one of those.
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    case start_link([]) do
      {:ok, _pid} ->
        migrate!(log: false)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end

  @doc """
  Run this repo's schema migrations - the one place that knows where they live, shared
  by both places that need to run them: `Pepe.Application`'s boot (a real supervised
  start) and `ensure_started/0` above (the `with_config` lazy-start path).
  """
  @spec migrate!(keyword()) :: :ok
  def migrate!(opts \\ []) do
    Ecto.Migrator.run(__MODULE__, Application.app_dir(:pepe, "priv/repo/migrations"), :up, Keyword.put(opts, :all, true))
    :ok
  end
end
