defmodule Pepe.Checkpoints.Restore do
  @moduledoc """
  Puts files back the way they were before some turns, and says exactly what it did.

  A rewind that touches files is only acceptable if it cannot make things worse, so every
  rule here is a refusal, decided per file:

    * **Only what a tool changed.** A path is restored only if a recorded tool call changed
      it. Nothing else in the folder is looked at, let alone touched.
    * **Only inside the allowed roots.** The roots are decided at restore time from the
      running session (the agent's workspace, the shared folder, the session's own working
      directory), never read from the record. A record is data on disk like any other, and
      a tampered one must not be able to name `/etc/hosts`. The path is also walked
      component by component: a symlink anywhere on the way in refuses the file, so a
      link pointing out of the workspace cannot carry a write with it.
    * **Only if nothing else touched it since.** The file must still hold exactly what the
      last recorded tool call left there. If the person edited it afterwards (or a command
      the checkpoints do not cover did), it is kept as it is and reported, never
      overwritten.
    * **Only from a copy that exists.** A file that was too large to copy, or that looked like
      a credential, has no stored "before" and is reported as such rather than guessed at.
    * **Nothing is thrown away silently.** Before a file is overwritten or removed, its
      current content is stored as a blob and listed in a `restore` record, so the rewind
      itself can be recovered by hand for as long as the store keeps it.
  """

  alias Pepe.Checkpoints.Snapshot
  alias Pepe.Checkpoints.Store

  @max_read 2 * 1_048_576

  @type report :: %{
          restored: [Path.t()],
          removed: [Path.t()],
          skipped: [%{path: Path.t(), reason: atom()}],
          untracked: [%{path: Path.t(), reason: atom()}],
          partial?: boolean()
        }

  @doc "An empty report."
  @spec empty() :: report()
  def empty, do: %{restored: [], removed: [], skipped: [], untracked: [], partial?: false}

  @doc """
  Restore the files the given `records` (oldest first) changed. `roots` are the directories a
  path must sit inside. With `dry_run: true` nothing is written and the report says what
  would happen.
  """
  @spec run([map()], [Path.t()], keyword()) :: report()
  def run(records, roots, opts \\ []) do
    dry? = Keyword.get(opts, :dry_run, false)
    roots = Enum.map(roots, &Path.expand/1)

    base = %{empty() | partial?: Enum.any?(records, &(&1["partial"] == true))}
    base = %{base | untracked: untracked(records)}

    records
    |> changes()
    |> Enum.reduce(base, fn change, report -> restore_one(change, roots, dry?, report) end)
    |> finish()
  end

  # One entry per path: what the file was before the first recorded change, and what the last
  # recorded change left. Oldest record first, so the first `before` really is the earliest.
  defp changes(records) do
    records
    |> Enum.flat_map(fn record -> List.wrap(record["files"]) end)
    |> Enum.filter(&is_binary(&1["path"]))
    |> Enum.reduce({[], %{}}, fn file, {order, by_path} ->
      path = file["path"]

      case by_path do
        %{^path => existing} ->
          {order, Map.put(by_path, path, %{existing | new: file["after"]})}

        _ ->
          entry = %{path: path, old: file["before"], new: file["after"], mode: file["mode"]}
          {[path | order], Map.put(by_path, path, entry)}
      end
    end)
    |> then(fn {order, by_path} -> order |> Enum.reverse() |> Enum.map(&by_path[&1]) end)
  end

  defp untracked(records) do
    records
    |> Enum.flat_map(fn record -> List.wrap(record["skipped"]) end)
    |> Enum.filter(&(is_binary(&1["path"]) and is_binary(&1["reason"])))
    |> Enum.map(&%{path: &1["path"], reason: reason_atom(&1["reason"])})
    |> Enum.uniq_by(& &1.path)
  end

  defp reason_atom("outside"), do: :outside
  defp reason_atom("sensitive"), do: :sensitive
  defp reason_atom(_), do: :untracked

  defp restore_one(change, roots, dry?, report) do
    with {:ok, root} <- within_roots(change.path, roots),
         {:ok, current} <- current_state(change.path),
         :ok <- unchanged_since(current, change.new),
         {:ok, target} <- target_state(change.old) do
      apply_change(change, root, current, target, dry?, report)
    else
      {:skip, reason} -> skip(report, change.path, reason)
    end
  end

  defp skip(report, path, reason), do: %{report | skipped: report.skipped ++ [%{path: path, reason: reason}]}

  ### the four refusals

  # Inside a root, and no symlink on the way in.
  defp within_roots(path, roots) do
    path = Path.expand(path)

    case Enum.find(roots, &inside?(path, &1)) do
      nil -> {:skip, :outside}
      root -> if clean_walk?(path, root), do: {:ok, root}, else: {:skip, :outside}
    end
  end

  defp inside?(path, root), do: path != root and String.starts_with?(path, root <> "/")

  # Every existing component from the root down must be a plain directory (or, last, a
  # plain file). `:file.read_link_info` does not follow links, which is the whole point.
  defp clean_walk?(path, root) do
    rel = Path.relative_to(path, root)
    parts = Path.split(rel)

    parts
    |> Enum.scan(root, fn part, acc -> Path.join(acc, part) end)
    |> Enum.all?(fn component ->
      case :file.read_link_info(String.to_charlist(component)) do
        {:ok, info} -> elem(info, 2) in [:directory, :regular]
        {:error, :enoent} -> true
        {:error, _} -> false
      end
    end)
  end

  # `{:ok, sha}` for a regular file, `{:ok, nil}` for no file at all.
  defp current_state(path) do
    case :file.read_link_info(String.to_charlist(path)) do
      {:error, :enoent} ->
        {:ok, nil}

      {:ok, info} when elem(info, 2) == :regular and elem(info, 1) > @max_read ->
        {:skip, :too_large}

      {:ok, info} when elem(info, 2) == :regular ->
        read_current(path)

      _ ->
        {:skip, :not_a_file}
    end
  end

  defp read_current(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, %{sha: Snapshot.sha(data), data: data}}
      {:error, _} -> {:skip, :unreadable}
    end
  end

  defp unchanged_since(nil, nil), do: :ok
  defp unchanged_since(nil, _after), do: {:skip, :changed_since}

  defp unchanged_since(%{sha: sha}, after_sha) do
    cond do
      not Snapshot.restorable_sha?(after_sha) -> if is_nil(after_sha), do: {:skip, :changed_since}, else: {:skip, :too_large}
      sha == after_sha -> :ok
      true -> {:skip, :changed_since}
    end
  end

  # What the file should become: `:absent` (it was created by those turns) or its old bytes.
  defp target_state(nil), do: {:ok, :absent}

  defp target_state(before) do
    if Snapshot.restorable_sha?(before), do: blob(before), else: {:skip, :not_copied}
  end

  defp blob(sha) do
    case Store.get_blob(sha) do
      {:ok, data} -> {:ok, {:content, sha, data}}
      :error -> {:skip, :expired}
    end
  end

  ### applying

  # Already what it should be (a file created and since removed, say): nothing to do.
  defp apply_change(_change, _root, nil, :absent, _dry?, report), do: report

  defp apply_change(change, root, current, target, dry?, report) do
    unless dry?, do: keep_copy(current, change.path, root, target)

    case {target, dry?} do
      {:absent, true} ->
        %{report | removed: report.removed ++ [change.path]}

      {:absent, false} ->
        remove(change.path, report)

      {{:content, _sha, _data}, true} ->
        %{report | restored: report.restored ++ [change.path]}

      {{:content, _sha, data}, false} ->
        write(change, data, report)
    end
  end

  defp remove(path, report) do
    case File.rm(path) do
      :ok -> %{report | removed: report.removed ++ [path]}
      {:error, _} -> skip(report, path, :unwritable)
    end
  end

  defp write(change, data, report) do
    tmp = change.path <> ".pepe-restore-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(change.path)),
         :ok <- File.write(tmp, data),
         :ok <- chmod(tmp, change.mode),
         :ok <- File.rename(tmp, change.path) do
      %{report | restored: report.restored ++ [change.path]}
    else
      {:error, _} ->
        File.rm(tmp)
        skip(report, change.path, :unwritable)
    end
  end

  # A record is data read back from disk, not something to trust with setuid/setgid/sticky
  # bits - mask to the permission bits only (0o777), never the full 0o7777 mode word.
  defp chmod(path, mode) when is_integer(mode), do: File.chmod(path, Bitwise.band(mode, 0o777))
  defp chmod(_path, _mode), do: :ok

  # The current content, kept before it is replaced. A restore record lists it so a person
  # who regrets a rewind can find the exact bytes again.
  defp keep_copy(nil, _path, _root, _target), do: :ok

  defp keep_copy(%{sha: sha, data: data}, path, root, target) do
    Store.put_blob(data)

    after_sha =
      case target do
        {:content, sha_after, _} -> sha_after
        :absent -> nil
      end

    record = %{
      "id" => Store.new_id(),
      "at" => System.os_time(:second),
      "kind" => "restore",
      "files" => [%{"path" => path, "before" => sha, "after" => after_sha, "mode" => nil, "size" => byte_size(data)}]
    }

    Store.write_record(Store.digest(root), root, record)
  end

  defp finish(report) do
    %{report | skipped: Enum.uniq_by(report.skipped, & &1.path)}
  end
end
