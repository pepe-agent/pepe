defmodule Pepe.Skills.Snapshots do
  @moduledoc """
  Content-addressed copies of the files a skill change replaced, so any single change in
  the ledger can be undone without restoring the whole library.

  `Pepe.Skills.Manage` stores the bytes of a file before and after every write here and puts
  the two hashes in the ledger row. `Pepe.Skills.Manage.undo/2` reads the *before* blob back.
  Blobs live under `<PEPE_HOME>/skills/.backups/blobs/`, beside the whole-library snapshots
  of `Pepe.Skills.Backup` and, like them, outside the skills index. Identical content is
  stored once. `prune/1` drops blobs older than a number of days; the curator calls it.
  """

  alias Pepe.Skills.Backup

  @doc "Where blobs are kept."
  @spec dir() :: String.t()
  def dir, do: Path.join(Backup.dir(), "blobs")

  @doc "Store `bytes` and return its hash (the blob's name)."
  @spec put(binary()) :: String.t()
  def put(bytes) when is_binary(bytes) do
    hash = hash(bytes)
    path = Path.join(dir(), hash)

    unless File.regular?(path) do
      File.mkdir_p!(dir())
      File.write!(path, bytes)
    end

    hash
  end

  @doc "The bytes stored under `hash`."
  @spec get(String.t() | nil) :: {:ok, binary()} | :error
  def get(hash) when is_binary(hash) do
    if valid?(hash) do
      case File.read(Path.join(dir(), hash)) do
        {:ok, bytes} -> {:ok, bytes}
        _ -> :error
      end
    else
      :error
    end
  end

  def get(_), do: :error

  @doc "The hash `put/1` would return for `bytes`, without storing anything."
  @spec hash(binary()) :: String.t()
  def hash(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc "Remove blobs last written more than `days` ago. Returns how many went."
  @spec prune(pos_integer()) :: non_neg_integer()
  def prune(days) when is_integer(days) and days > 0 do
    cutoff = System.os_time(:second) - days * 86_400

    case File.ls(dir()) do
      {:ok, names} ->
        Enum.count(names, &prune_blob(Path.join(dir(), &1), cutoff))

      _ ->
        0
    end
  end

  defp prune_blob(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} when mtime < cutoff -> File.rm(path) == :ok
      _ -> false
    end
  end

  # A hash is 64 hex characters; anything else could be a path.
  defp valid?(hash), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)
end
