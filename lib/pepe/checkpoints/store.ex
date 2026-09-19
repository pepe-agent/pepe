defmodule Pepe.Checkpoints.Store do
  @moduledoc """
  The on-disk half of `Pepe.Checkpoints`: content-addressed file blobs, one JSON record
  per recorded change, and a small per-session log tying those records to conversation
  turns.

  Everything lives under `<PEPE_HOME>/checkpoints/` and is plain files, so a checkpoint
  can be inspected, copied or deleted by hand and nothing here needs a migration:

      blobs/ab/abcdef...            file contents, named by their SHA-256
      scopes/<scope>/scope.json     which directory a scope is
      scopes/<scope>/<id>.json      one recorded change
      sessions/<key>.json           per-session turn log (see `Pepe.Checkpoints`)

  Writes are atomic (temp file plus rename) so a crash mid-write leaves the previous
  version, never half of a new one. Every path read back from a record is validated
  before it is used as a file name: a hash must be 64 hex characters, an id must match
  the id format. A record is data on disk like any other, and turning a tampered one into
  a write outside the store is the classic way a "restore" feature becomes a hazard.
  """

  alias Pepe.Config

  @id_re ~r/\A\d{16}-\d{4}\z/
  @sha_re ~r/\A[0-9a-f]{64}\z/

  @doc "Root directory of the store."
  @spec root() :: Path.t()
  def root, do: Path.join(Config.home(), "checkpoints")

  @doc "Stable 16-hex identifier for a directory (a scope) or a session key."
  @spec digest(String.t()) :: String.t()
  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  @doc "A fresh, time-ordered record id: lexicographic order is chronological order."
  @spec new_id() :: String.t()
  def new_id do
    us = System.os_time(:microsecond)
    n = rem(System.unique_integer([:positive, :monotonic]), 10_000)
    :io_lib.format("~16..0B-~4..0B", [us, n]) |> IO.iodata_to_binary()
  end

  @doc "Whether a string has the shape of a record id."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_binary(id) and Regex.match?(@id_re, id)

  @doc "Whether a string has the shape of a blob hash."
  @spec valid_sha?(term()) :: boolean()
  def valid_sha?(sha), do: is_binary(sha) and Regex.match?(@sha_re, sha)

  ### blobs

  defp blob_path(sha), do: Path.join([root(), "blobs", binary_part(sha, 0, 2), sha])

  @doc "Store `data` under its own hash (a no-op when already stored). Returns the hash."
  @spec put_blob(binary()) :: String.t()
  def put_blob(data) do
    sha = Pepe.Checkpoints.Snapshot.sha(data)
    path = blob_path(sha)
    if not File.exists?(path), do: atomic_write(path, data)
    sha
  end

  @doc "Read a blob back; `:error` for an unknown or malformed hash."
  @spec get_blob(term()) :: {:ok, binary()} | :error
  def get_blob(sha) do
    if valid_sha?(sha) do
      case File.read(blob_path(sha)) do
        {:ok, data} -> {:ok, data}
        {:error, _} -> :error
      end
    else
      :error
    end
  end

  ### records

  defp scope_dir(scope_id), do: Path.join([root(), "scopes", scope_id])
  defp record_path(scope_id, id), do: Path.join(scope_dir(scope_id), id <> ".json")

  @doc "Persist a record (and its scope's `scope.json`, first time)."
  @spec write_record(String.t(), String.t(), map()) :: :ok
  def write_record(scope_id, scope_dir_path, %{"id" => id} = record) do
    meta = Path.join(scope_dir(scope_id), "scope.json")
    if not File.exists?(meta), do: atomic_write(meta, Jason.encode!(%{"dir" => scope_dir_path}))
    atomic_write(record_path(scope_id, id), Jason.encode!(record))
  end

  @doc "Replace an existing record (used to mark it reverted)."
  @spec update_record(String.t(), String.t(), (map() -> map())) :: :ok | :error
  def update_record(scope_id, id, fun) do
    case read_record(scope_id, id) do
      {:ok, record} -> atomic_write(record_path(scope_id, id), Jason.encode!(fun.(record)))
      :error -> :error
    end
  end

  @doc "Read one record."
  @spec read_record(String.t(), String.t()) :: {:ok, map()} | :error
  def read_record(scope_id, id) do
    with true <- valid_id?(id),
         {:ok, body} <- File.read(record_path(scope_id, id)),
         {:ok, %{} = record} <- Jason.decode(body) do
      {:ok, record}
    else
      _ -> :error
    end
  end

  @doc "All record ids in a scope, newest first."
  @spec record_ids(String.t()) :: [String.t()]
  def record_ids(scope_id) do
    case File.ls(scope_dir(scope_id)) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.replace_suffix(&1, ".json", ""))
        |> Enum.filter(&valid_id?/1)
        |> Enum.sort(:desc)

      {:error, _} ->
        []
    end
  end

  @doc "Delete a record."
  @spec delete_record(String.t(), String.t()) :: :ok
  def delete_record(scope_id, id) do
    if valid_id?(id), do: File.rm(record_path(scope_id, id))
    :ok
  end

  @doc "Every scope id present on disk."
  @spec scope_ids() :: [String.t()]
  def scope_ids do
    case File.ls(Path.join(root(), "scopes")) do
      {:ok, names} -> Enum.filter(names, &File.dir?(scope_dir(&1)))
      {:error, _} -> []
    end
  end

  @doc "The directory a scope id stands for, if its `scope.json` is readable."
  @spec scope_path(String.t()) :: Path.t() | nil
  def scope_path(scope_id) do
    with {:ok, body} <- File.read(Path.join(scope_dir(scope_id), "scope.json")),
         {:ok, %{"dir" => dir}} when is_binary(dir) <- Jason.decode(body) do
      dir
    else
      _ -> nil
    end
  end

  @doc "Remove a whole scope directory."
  @spec delete_scope(String.t()) :: :ok
  def delete_scope(scope_id) do
    File.rm_rf(scope_dir(scope_id))
    :ok
  end

  ### per-session turn log

  defp log_path(key), do: Path.join([root(), "sessions", digest(key) <> ".json"])

  @doc """
  Read-modify-write a session's log under a lock. `fun` gets the current log (a map with
  `"turns"` and `"pending"`) and returns the new one; the value of `fun` is written and
  also returned. The lock is per session key, so two sessions never wait on each other.
  """
  @spec update_log(String.t(), (map() -> map())) :: map()
  def update_log(key, fun) do
    :global.trans({{:pepe_checkpoints_log, digest(key)}, self()}, fn ->
      new = fun.(read_log(key))
      atomic_write(log_path(key), Jason.encode!(new))
      new
    end)
  end

  @doc "A session's turn log (empty when there is none)."
  @spec read_log(String.t()) :: map()
  def read_log(key) do
    with {:ok, body} <- File.read(log_path(key)),
         {:ok, %{} = log} <- Jason.decode(body) do
      %{"turns" => List.wrap(log["turns"]), "pending" => List.wrap(log["pending"])}
    else
      _ -> %{"turns" => [], "pending" => []}
    end
  end

  @doc "Forget a session's log."
  @spec delete_log(String.t()) :: :ok
  def delete_log(key) do
    File.rm(log_path(key))
    :ok
  end

  @doc "Every session log path (for pruning stale ones)."
  @spec log_files() :: [Path.t()]
  def log_files do
    dir = Path.join(root(), "sessions")

    case File.ls(dir) do
      {:ok, names} -> Enum.map(names, &Path.join(dir, &1))
      {:error, _} -> []
    end
  end

  ### blob housekeeping

  @doc "Every blob on disk as `{sha, path, size}`."
  @spec blobs() :: [{String.t(), Path.t(), non_neg_integer()}]
  def blobs do
    base = Path.join(root(), "blobs")

    case File.ls(base) do
      {:ok, shards} ->
        for shard <- shards,
            dir = Path.join(base, shard),
            File.dir?(dir),
            {:ok, names} <- [File.ls(dir)],
            name <- names,
            valid_sha?(name),
            path = Path.join(dir, name),
            {:ok, %{size: size}} <- [File.stat(path)] do
          {name, path, size}
        end

      {:error, _} ->
        []
    end
  end

  @doc "Total bytes used by the whole store."
  @spec bytes() :: non_neg_integer()
  def bytes do
    blob_bytes = blobs() |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    record_bytes =
      for scope <- scope_ids(), id <- record_ids(scope), {:ok, %{size: s}} <- [File.stat(record_path(scope, id))], reduce: 0 do
        acc -> acc + s
      end

    blob_bytes + record_bytes
  end

  ### plumbing

  @doc false
  def atomic_write(path, data) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    File.write!(tmp, data)
    File.rename!(tmp, path)
    :ok
  end
end
