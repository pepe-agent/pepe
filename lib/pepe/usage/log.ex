defmodule Pepe.Usage.Log do
  @moduledoc """
  Append-only token-usage ledger - the durable record billing is built on.

  One JSONL file per project per month under
  `<PEPE_HOME>/data/usage/<project>/YYYY-MM.jsonl` (the root scope lives under
  `root/`). Every model call the runtime makes appends one line:

      {"at": 1720000000, "agent": "acme/sales", "model": "gpt-4o", "in": 812, "out": 143}

  The project is the directory, so it isn't repeated per line. Partitioning by
  month keeps files bounded and lets a period read touch only the months it needs.
  Append-only + never-expiring (unlike `Pepe.Store`) because it is the audit
  trail for what a client is charged.
  """

  alias Pepe.Config

  @doc "Root directory holding the per-project usage ledgers."
  def dir, do: Path.join([Config.home(), "data", "usage"])

  @doc "The directory for one scope (`nil`/`\"root\"` -> `root/`)."
  def scope_dir(scope), do: Path.join(dir(), scope_name(scope))

  @doc """
  Append one usage entry to `project`'s ledger for the month of `entry["at"]`.
  `entry` carries `at`, `agent`, `model`, `in`, `out`.
  """
  @spec append(String.t() | nil, map()) :: :ok
  def append(project, entry) do
    d = scope_dir(project)
    File.mkdir_p!(d)
    File.write!(Path.join(d, month_file(entry["at"])), Jason.encode!(entry) <> "\n", [:append])
    :ok
  end

  @doc "Scopes (projects + root) that have any recorded usage."
  def scopes do
    case File.ls(dir()) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  @doc """
  All entries for a scope across every month, each decorated with its `project`
  (the scope name). Newest last (file/append order).
  """
  @spec entries(String.t() | nil) :: [map()]
  def entries(scope) do
    d = scope_dir(scope)
    name = scope_name(scope)

    case File.ls(d) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort()
        |> Enum.flat_map(fn f -> read_file(Path.join(d, f)) end)
        |> Enum.map(&Map.put(&1, "project", name))

      _ ->
        []
    end
  end

  @doc "All entries across the given scopes (or all scopes when `:all`)."
  @spec entries_for(:all | [String.t()]) :: [map()]
  def entries_for(:all), do: Enum.flat_map(scopes(), &entries/1)
  def entries_for(list) when is_list(list), do: Enum.flat_map(list, &entries/1)

  @doc """
  Entries for a scope, but only from the ledger files that could contain "now"'s billing month -
  the file partitioning is by UTC month, while a "current month" query filters by the operator's
  configured billing timezone, so an entry near a month boundary can sit in the UTC month either
  side of it (a timezone ahead of UTC can have its month start in UTC's previous month; one behind
  UTC can have its month end spill into UTC's next). Reading the UTC month either side of `at`
  covers any real-world offset without having to know the timezone here.

  For `month_to_date/1` (called every turn a project has a budget), this turns an O(every month
  the scope has ever recorded) read into a bounded 3-file one, and only when it actually helps -
  once a scope's whole history already fits in 3 months, `entries/1` and this return the same set.
  """
  @spec entries_near(String.t() | nil, integer()) :: [map()]
  def entries_near(scope, at \\ System.os_time(:second)) do
    d = scope_dir(scope)
    name = scope_name(scope)
    {y, m, _d} = at |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_erl()

    [{y, m - 1}, {y, m}, {y, m + 1}]
    |> Enum.map(&normalize_month/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn {yy, mm} -> read_file(Path.join(d, month_filename(yy, mm))) end)
    |> Enum.map(&Map.put(&1, "project", name))
  end

  defp normalize_month({y, 0}), do: {y - 1, 12}
  defp normalize_month({y, 13}), do: {y + 1, 1}
  defp normalize_month({y, m}), do: {y, m}

  defp month_filename(y, m), do: :io_lib.format("~4..0B-~2..0B.jsonl", [y, m]) |> to_string()

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&decode/1)
        |> Enum.reject(&is_nil/1)

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

  # Partition file by the entry's UTC month - a storage bucket, independent of the
  # timezone used later to draw billing-day boundaries.
  defp month_file(at) when is_integer(at) do
    dt = DateTime.from_unix!(at)
    month_filename(dt.year, dt.month)
  end

  defp month_file(_), do: "unknown.jsonl"
end
