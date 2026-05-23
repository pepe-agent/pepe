defmodule Pepe.Usage.Messages do
  @moduledoc """
  Append-only counter of customer-originated messages per project per month - the
  source of truth for `Pepe.Config.project_message_limit/1`'s monthly cap.

  Kept as its own ledger under `<PEPE_HOME>/data/messages/<project>/YYYY-MM.jsonl`,
  separate from `Pepe.Usage.Log` (the token/cost ledger): one customer message can
  trigger several model calls, so counting `Log` entries would overcount, and
  mixing entry shapes into that ledger would break its billing summary/invoice math.
  """

  alias Pepe.Config

  @doc "Root directory holding the per-project message counters."
  def dir, do: Path.join([Config.home(), "data", "messages"])

  @doc "The directory for one scope (`nil`/`\"root\"` -> `root/`)."
  def scope_dir(scope), do: Path.join(dir(), scope_name(scope))

  @doc "Record one customer-originated message for `project` (`nil` counts against root)."
  @spec record(String.t() | nil) :: :ok
  def record(project) do
    d = scope_dir(project)
    File.mkdir_p!(d)
    at = System.system_time(:second)
    File.write!(Path.join(d, month_file(at)), Jason.encode!(%{"at" => at}) <> "\n", [:append])
    :ok
  end

  @doc """
  Reset `project`'s counter early, before the natural month boundary - appends a
  reset marker rather than deleting anything, so the ledger stays a full audit
  trail; messages recorded before the marker just stop counting toward the cap.
  """
  @spec reset(String.t() | nil) :: :ok
  def reset(project) do
    d = scope_dir(project)
    File.mkdir_p!(d)
    at = System.system_time(:second)
    File.write!(Path.join(d, month_file(at)), Jason.encode!(%{"at" => at, "reset" => true}) <> "\n", [:append])
    :ok
  end

  @doc """
  How many messages `project` has been recorded for since the later of: the start
  of the current billing month, or its last `reset/1` (if any fell within it).
  """
  @spec month_to_date(String.t() | nil) :: non_neg_integer()
  def month_to_date(project) do
    tz = Config.default_timezone()
    key = bucket_key(System.os_time(:second), tz)

    this_month =
      project |> entries() |> Enum.filter(&(bucket_key(&1["at"], tz) == key)) |> Enum.with_index()

    # Break ties on append order (list position), not the raw second-resolution
    # timestamp - a record and a reset in the same wall-clock second are common
    # (tests, or just a burst of traffic) and would otherwise sort ambiguously.
    last_reset_index =
      this_month
      |> Enum.filter(fn {e, _i} -> e["reset"] end)
      |> List.last()
      |> case do
        nil -> -1
        {_e, i} -> i
      end

    Enum.count(this_month, fn {e, i} -> !e["reset"] and i > last_reset_index end)
  end

  @doc "Unix timestamp of `project`'s last reset within the current billing month, or `nil`."
  @spec last_reset_at(String.t() | nil) :: integer() | nil
  def last_reset_at(project) do
    tz = Config.default_timezone()
    key = bucket_key(System.os_time(:second), tz)

    project
    |> entries()
    |> Enum.filter(&(bucket_key(&1["at"], tz) == key and &1["reset"]))
    |> Enum.map(& &1["at"])
    |> case do
      [] -> nil
      ats -> Enum.max(ats)
    end
  end

  defp entries(project) do
    d = scope_dir(project)

    case File.ls(d) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.flat_map(fn f -> read_file(Path.join(d, f)) end)

      _ ->
        []
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents |> String.split("\n", trim: true) |> Enum.map(&decode/1) |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} -> map
      _ -> nil
    end
  end

  defp scope_name(scope) when scope in [nil, ""], do: Config.default_project_slug()
  defp scope_name(scope), do: to_string(scope)

  # Storage partition (raw UTC month) - just keeps files bounded; the actual
  # billing-month boundary used for counting is bucket_key/2, in the configured tz.
  defp month_file(at) do
    dt = DateTime.from_unix!(at)
    :io_lib.format("~4..0B-~2..0B.jsonl", [dt.year, dt.month]) |> to_string()
  end

  defp bucket_key(at, tz) do
    dt =
      with {:ok, utc} <- DateTime.from_unix(at),
           {:ok, local} <- DateTime.shift_zone(utc, tz) do
        local
      else
        _ -> DateTime.from_unix!(at || 0)
      end

    :io_lib.format("~4..0B-~2..0B", [dt.year, dt.month]) |> to_string()
  end
end
