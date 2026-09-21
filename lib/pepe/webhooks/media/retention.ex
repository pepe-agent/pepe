defmodule Pepe.Webhooks.Media.Retention do
  @moduledoc """
  How long inbound attachments stay in an agent's workspace, and how much room they may take.

  Every attachment a webhook channel accepts is written to `<workspace>/media/` so the agent
  can still reach the original after the words have been extracted. The per-file cap
  (`Pepe.Webhooks.Media.max_bytes/0`) bounds one upload; nothing about it bounds *many*, and
  a WhatsApp number or a Discord channel is reachable by anyone who has it. Without a limit
  a stream of permitted files fills the host's disk.

  So each store prunes the directory it just wrote to, in two passes:

    1. anything older than #{14} days goes, whatever the total;
    2. if what is left is still over #{1} GiB, the oldest files go first until it fits.

  The file that triggered the prune is never removed by it, so the attachment being handed
  to the agent right now cannot vanish under it, however small the budget.

  The directory is flat and written only by `Pepe.Webhooks.Media`, so a listing is cheap; the
  work happens per accepted attachment, not on a timer, so an idle agent costs nothing.
  """

  require Logger

  @max_age_days 14
  @max_total_bytes 1_073_741_824

  @doc "The age, in days, past which an attachment is removed."
  @spec max_age_days() :: pos_integer()
  def max_age_days, do: @max_age_days

  @doc "The most bytes the media directory of one agent is allowed to hold."
  @spec max_total_bytes() :: pos_integer()
  def max_total_bytes, do: @max_total_bytes

  @doc """
  Prune `dir`. `keep` is the file name (not a path) that must survive. Options `:max_age_days`,
  `:max_total_bytes` and `:now` (seconds, for tests) override the defaults. Returns the number
  of files removed.
  """
  @spec prune(Path.t(), String.t() | nil, keyword()) :: non_neg_integer()
  def prune(dir, keep \\ nil, opts \\ []) do
    max_age = Keyword.get(opts, :max_age_days, @max_age_days) * 86_400
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes)
    now = Keyword.get(opts, :now, System.os_time(:second))

    files = list(dir)
    {stale, fresh} = Enum.split_with(files, fn f -> f.name != keep and now - f.mtime > max_age end)

    removed = remove(stale)
    removed + remove(over_budget(fresh, keep, max_total))
  end

  # Oldest first, until the rest fits. The kept file counts toward the total but is never a
  # candidate, so a budget smaller than that one file removes everything else and stops.
  defp over_budget(files, keep, max_total) do
    total = files |> Enum.map(& &1.size) |> Enum.sum()

    files
    |> Enum.reject(&(&1.name == keep))
    |> Enum.sort_by(& &1.mtime)
    |> Enum.reduce_while({total, []}, fn file, {left, doomed} ->
      if left > max_total, do: {:cont, {left - file.size, [file | doomed]}}, else: {:halt, {left, doomed}}
    end)
    |> elem(1)
  end

  defp remove(files) do
    Enum.count(files, fn file ->
      case File.rm(file.path) do
        :ok ->
          true

        {:error, reason} ->
          Logger.warning("[webhooks] could not prune #{file.path}: #{inspect(reason)}")
          false
      end
    end)
  end

  defp list(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.flat_map(names, &file_entry(dir, &1))
      {:error, _} -> []
    end
  end

  defp file_entry(dir, name) do
    path = Path.join(dir, name)

    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} -> [%{name: name, path: path, size: size, mtime: mtime}]
      _ -> []
    end
  end
end
