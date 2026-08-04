defmodule Pepe.DB do
  @moduledoc """
  Facade for the `db_query` tool's connections to operator-configured external Postgres
  databases (customer data, not Pepe's own SQLite store).

  Configured connections (`Pepe.Config.db_connections/0`) are launched **on demand** - one
  Postgrex connection per named connection, started lazily under a DynamicSupervisor and
  cached in a Registry, mirroring `Pepe.MCP`/`Pepe.Browser`'s exact shape: the first query
  against a connection pays the spawn cost, every query after reuses it.

  This module owns only the connection lifecycle. The tenant-isolation contract (resolving
  the trusted tenant value, `set_config` before every query, the read-only guard) lives in
  `Pepe.DB.Query` - kept separate so the lazy-start/registry mechanics can be tested and
  reasoned about independently of the security-relevant query logic.
  """

  alias Pepe.Config

  @registry Pepe.DB.Registry
  @sup Pepe.DB.DynSup

  @doc "Ensure the connection for `name` is running, starting it if needed."
  @spec ensure(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> start(name)
    end
  end

  @doc """
  Stop the running connection for `name`, if any - it respawns lazily on the next use. A
  recovery lever for a wedged connection, or the way credential rotation takes effect (there
  is no push-based reconfiguration, same as `Pepe.MCP.restart/1`). No-op when nothing is running.
  """
  @spec restart(String.t()) :: :ok
  def restart(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@sup, pid) |> discard()
      [] -> :ok
    end
  end

  defp start(name) do
    case Config.db_connection(name) do
      nil -> {:error, {:unknown_connection, name}}
      cfg -> spawn_conn(name, cfg)
    end
  end

  defp spawn_conn(name, cfg) do
    opts = [
      hostname: cfg.host,
      port: cfg.port,
      database: cfg.database,
      username: cfg.user,
      password: cfg.password,
      pool_size: 2,
      name: via(name)
    ]

    case DynamicSupervisor.start_child(@sup, %{id: {:db, name}, start: {Postgrex, :start_link, [opts]}, restart: :temporary}) do
      {:ok, pid} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  defp via(name), do: {:via, Registry, {@registry, name}}

  defp discard(_), do: :ok
end
