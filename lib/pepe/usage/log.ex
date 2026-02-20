defmodule Pepe.Usage.Log do
  @moduledoc """
  Append-only token-usage ledger — the durable record billing is built on.

  One JSONL file per company per month under
  `<PEPE_HOME>/data/usage/<company>/YYYY-MM.jsonl` (the root scope lives under
  `root/`). Every model call the runtime makes appends one line:

      {"at": 1720000000, "agent": "acme/sales", "model": "gpt-4o", "in": 812, "out": 143}

  The company is the directory, so it isn't repeated per line. Partitioning by
  month keeps files bounded and lets a period read touch only the months it needs.
  Append-only + never-expiring (unlike `Pepe.Store`) because it is the audit
  trail for what a client is charged.
  """

  alias Pepe.Config

  @doc "Root directory holding the per-company usage ledgers."
  def dir, do: Path.join([Config.home(), "data", "usage"])

  @doc "The directory for one scope (`nil`/`\"root\"` → `root/`)."
  def scope_dir(scope), do: Path.join(dir(), scope_name(scope))

  @doc """
  Append one usage entry to `company`'s ledger for the month of `entry["at"]`.
  `entry` carries `at`, `agent`, `model`, `in`, `out`.
  """
  @spec append(String.t() | nil, map()) :: :ok
  def append(company, entry) do
    d = scope_dir(company)
    File.mkdir_p!(d)
    File.write!(Path.join(d, month_file(entry["at"])), Jason.encode!(entry) <> "\n", [:append])
    :ok
  end

  @doc "Scopes (companies + root) that have any recorded usage."
  def scopes do
    case File.ls(dir()) do
      {:ok, names} -> Enum.sort(names)
      _ -> []
    end
  end

  @doc """
  All entries for a scope across every month, each decorated with its `company`
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
        |> Enum.map(&Map.put(&1, "company", name))

      _ ->
        []
    end
  end

  @doc "All entries across the given scopes (or all scopes when `:all`)."
  @spec entries_for(:all | [String.t()]) :: [map()]
  def entries_for(:all), do: Enum.flat_map(scopes(), &entries/1)
  def entries_for(list) when is_list(list), do: Enum.flat_map(list, &entries/1)

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

  defp scope_name(scope) when scope in [nil, "", "root"], do: "root"
  defp scope_name(scope), do: to_string(scope)

  # Partition file by the entry's UTC month — a storage bucket, independent of the
  # timezone used later to draw billing-day boundaries.
  defp month_file(at) when is_integer(at) do
    dt = DateTime.from_unix!(at)
    :io_lib.format("~4..0B-~2..0B.jsonl", [dt.year, dt.month]) |> to_string()
  end

  defp month_file(_), do: "unknown.jsonl"
end
