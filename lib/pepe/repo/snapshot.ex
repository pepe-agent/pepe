defmodule Pepe.Repo.Snapshot do
  @moduledoc """
  Point-in-time SQLite snapshots for `mix pepe backup`/`restore`, taken through `VACUUM INTO`
  on the live `Pepe.Repo` connection - transactionally consistent under WAL, unlike raw-tar'ing
  `data/pepe.db*` mid-write (the bug this exists to close: `mix pepe backup` used to exclude
  only `data/mnesia` and tar the live database files with zero WAL coordination, the same class
  of bug already hit once during the SQLite migration).

  `VACUUM INTO` runs while the app stays live: no daemon stop, no separate checkpoint step, and
  the produced file is a compact, WAL-free single file - nothing else to get right about a
  `-wal`/`-shm` companion.
  """

  @doc """
  Snapshot the live `Pepe.Repo` database into `dest` (its parent directory is created if
  needed; `dest` must not already exist - `VACUUM INTO` refuses to overwrite).
  """
  @spec vacuum_into(String.t()) :: :ok | {:error, term()}
  def vacuum_into(dest) do
    File.mkdir_p!(Path.dirname(dest))

    case Pepe.Repo.query("VACUUM INTO ?", [dest]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `PRAGMA integrity_check` against `path`, opened read-only and independent of any Ecto
  pool/connection - works on a file nothing else has touched yet, e.g. a freshly produced
  snapshot or one just unpacked from an archive.
  """
  @spec integrity_check(String.t()) :: :ok | {:error, term()}
  def integrity_check(path) do
    case Exqlite.Sqlite3.open(path, mode: [:readonly, :nomutex]) do
      {:ok, conn} ->
        try do
          run_integrity_check(conn)
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_integrity_check(conn) do
    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, "PRAGMA integrity_check"),
         {:ok, rows} <- Exqlite.Sqlite3.fetch_all(conn, stmt) do
      case rows do
        [["ok"]] -> :ok
        problems -> {:error, Enum.map(problems, &List.first/1)}
      end
    end
  end

  @doc """
  Can `path` be opened for an exclusive write right now? A pragmatic, not perfect, liveness
  check for `mix pepe restore`: it catches a daemon actively mid-write (SQLite reports the
  database as busy), but not "a process holds it open but is currently idle" - there is no
  pidfile or other process registry in Pepe to check instead, and this is cheap and correct
  for the case that actually matters: never swap a fresh install into place under a writer
  that's using it right now.
  """
  @spec writable?(String.t()) :: boolean()
  def writable?(path) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} ->
        try do
          case Exqlite.Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
            :ok ->
              Exqlite.Sqlite3.execute(conn, "ROLLBACK")
              true

            {:error, _reason} ->
              false
          end
        after
          Exqlite.Sqlite3.close(conn)
        end

      {:error, _reason} ->
        false
    end
  end
end
