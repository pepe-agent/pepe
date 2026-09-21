defmodule Pepe.Checkpoints.Retention do
  @moduledoc """
  How long checkpoints are kept, and how much room they may take.

  A checkpoint is a safety net for the next few days, not an archive, so the store is bounded
  three ways and pruned with all three every time it runs:

    1. a record older than #{14} days goes, whatever the total;
    2. a per-session turn log nobody has touched for #{30} days goes;
    3. if what is left is still over #{512} MiB, the oldest records go first until it fits.

  Then any blob no remaining record points at is deleted. A blob younger than an hour is
  never collected, because a blob is written just before the record that names it and the
  collector must not win that race.

  Pruning is driven by use, not by a timer: `maybe_prune/0` runs after a turn is recorded and
  does real work at most once every six hours (a marker file remembers when), so an idle
  install costs nothing and a busy one pays for one directory listing a day. The same work
  is available by hand as `mix pepe checkpoints prune`.
  """

  alias Pepe.Checkpoints.Store

  @max_age_days 14
  @session_log_days 30
  @max_bytes 512 * 1_048_576
  @blob_grace_seconds 3_600
  @interval_seconds 6 * 3_600

  @doc "Age in days past which a record is removed."
  @spec max_age_days() :: pos_integer()
  def max_age_days, do: @max_age_days

  @doc "The most bytes the store is allowed to hold."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Prune now. Options `:max_age_days`, `:max_bytes` and `:now` (microseconds, for tests)
  override the defaults. Returns what was removed.
  """
  @spec prune(keyword()) :: %{records: non_neg_integer(), blobs: non_neg_integer(), logs: non_neg_integer(), bytes: non_neg_integer()}
  def prune(opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:microsecond))
    age = Keyword.get(opts, :max_age_days, @max_age_days)
    cap = Keyword.get(opts, :max_bytes, @max_bytes)
    before_bytes = Store.bytes()

    old = delete_old_records(now - age * 86_400 * 1_000_000)
    logs = delete_stale_logs(now)
    over = shrink_to(cap)
    blobs = collect_blobs(now)
    drop_empty_scopes()

    %{records: old + over, blobs: blobs, logs: logs, bytes: max(before_bytes - Store.bytes(), 0)}
  end

  @doc """
  Prune if it has not run in the last six hours. Cheap when it has: one `stat` of a marker.
  Returns `:ok` either way.
  """
  @spec maybe_prune() :: :ok
  def maybe_prune do
    marker = Path.join(Store.root(), ".last_prune")

    if due?(marker) do
      File.mkdir_p!(Store.root())
      File.write!(marker, Integer.to_string(System.os_time(:second)))

      if Application.get_env(:pepe, :checkpoints_async_prune, true) do
        Task.start(fn -> prune() end)
      else
        prune()
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp due?(marker) do
    case File.stat(marker, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> System.os_time(:second) - mtime >= @interval_seconds
      {:error, _} -> true
    end
  end

  @doc "A summary of what the store holds, for `mix pepe checkpoints status`."
  @spec status() :: map()
  def status do
    scopes = Store.scope_ids()
    ids = for scope <- scopes, id <- Store.record_ids(scope), do: id

    %{
      bytes: Store.bytes(),
      scopes: length(scopes),
      records: length(ids),
      blobs: length(Store.blobs()),
      sessions: length(Store.log_files()),
      oldest: ids |> Enum.map(&timestamp/1) |> Enum.min(fn -> nil end)
    }
  end

  @doc "Delete every checkpoint. Returns the number of bytes freed."
  @spec clear() :: non_neg_integer()
  def clear do
    freed = Store.bytes()
    File.rm_rf(Store.root())
    freed
  end

  ### steps

  # Record ids are `<microseconds>-<n>`, so age comes from the name and nothing is read.
  defp timestamp(id), do: id |> binary_part(0, 16) |> String.to_integer()

  defp delete_old_records(cutoff) do
    for scope <- Store.scope_ids(),
        id <- Store.record_ids(scope),
        timestamp(id) < cutoff,
        reduce: 0 do
      acc ->
        Store.delete_record(scope, id)
        acc + 1
    end
  end

  defp delete_stale_logs(now_us) do
    cutoff_s = div(now_us, 1_000_000) - @session_log_days * 86_400

    Enum.count(Store.log_files(), fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{mtime: mtime}} when mtime < cutoff_s -> File.rm(path) == :ok
        _ -> false
      end
    end)
  end

  # Oldest first, a tenth of what is left at a time, until under the cap. Blobs are only
  # freed by the collector afterwards, so the size is re-measured after each round.
  defp shrink_to(cap), do: shrink_to(cap, 0, 0)

  defp shrink_to(_cap, deleted, rounds) when rounds >= 25, do: deleted

  defp shrink_to(cap, deleted, rounds) do
    if Store.bytes() <= cap do
      deleted
    else
      oldest = for scope <- Store.scope_ids(), id <- Store.record_ids(scope), do: {id, scope}
      batch = oldest |> Enum.sort() |> Enum.take(max(div(length(oldest), 10), 1))

      drop_batch(batch, cap, deleted, rounds)
    end
  end

  defp drop_batch([], _cap, deleted, _rounds), do: deleted

  defp drop_batch(batch, cap, deleted, rounds) do
    Enum.each(batch, fn {id, scope} -> Store.delete_record(scope, id) end)
    collect_blobs(System.os_time(:microsecond), 0)
    shrink_to(cap, deleted + length(batch), rounds + 1)
  end

  defp collect_blobs(now_us, grace \\ @blob_grace_seconds) do
    keep = referenced_blobs()
    cutoff_s = div(now_us, 1_000_000) - grace

    Enum.count(Store.blobs(), fn {sha, path, _size} ->
      not MapSet.member?(keep, sha) and old_enough?(path, cutoff_s) and File.rm(path) == :ok
    end)
  end

  defp old_enough?(path, cutoff_s) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime <= cutoff_s
      {:error, _} -> false
    end
  end

  defp referenced_blobs do
    for scope <- Store.scope_ids(),
        id <- Store.record_ids(scope),
        {:ok, record} <- [Store.read_record(scope, id)],
        file <- List.wrap(record["files"]),
        is_map(file),
        sha = file["before"],
        Store.valid_sha?(sha),
        into: MapSet.new(),
        do: sha
  end

  defp drop_empty_scopes do
    for scope <- Store.scope_ids(), Store.record_ids(scope) == [], do: Store.delete_scope(scope)
    :ok
  end
end
