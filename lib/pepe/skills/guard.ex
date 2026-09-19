defmodule Pepe.Skills.Guard do
  @moduledoc """
  Scans a whole skill on disk - its entry doc and every file it ships - and decides what
  may be done with the result.

  `Pepe.Skills.Sentinel` knows how to read one piece of text or code; this module knows
  what a *skill* is: a doc plus whatever sits beside it. It is the single place that turns
  a directory into a verdict, used at install time, when auditing what is installed, and
  before a project-local skill is allowed to load.

  Scans are cached by a digest of the skill's files (path and bytes), so a project skill
  costs one scan per change to its content, not one per turn.
  """

  alias Pepe.Skills
  alias Pepe.Skills.Sentinel

  @cache {__MODULE__, :scans}

  @doc """
  Scan a skill package directory: the entry doc as skill markdown, every other regular
  file as code-or-text. Symlinks are never followed (they are reported, since one that
  points outside the package would let the skill read files it does not ship).
  """
  @spec scan_package(String.t()) :: %{verdict: Sentinel.verdict(), findings: [Sentinel.finding()]}
  def scan_package(dir) do
    entry = Skills.package_entry(dir)
    doc = if entry, do: File.read!(entry), else: ""

    code_scans =
      dir
      |> package_files(entry)
      |> Enum.map(fn path -> Sentinel.scan_code(File.read!(path), Path.relative_to(path, dir)) end)

    Sentinel.merge([Sentinel.scan(doc) | code_scans] ++ structure_scans(dir))
  end

  @doc "`scan_package/1`, memoized by the digest of the package's content."
  @spec scan_package_cached(String.t()) :: %{verdict: Sentinel.verdict(), findings: [Sentinel.finding()]}
  def scan_package_cached(dir) do
    key = digest(dir)

    case cache()[key] do
      %{verdict: _, findings: _} = hit ->
        hit

      _miss ->
        result = scan_package(dir)
        :persistent_term.put(@cache, Map.put(cache(), key, result))
        result
    end
  end

  @doc "A digest of a directory's files: relative path and bytes, in a stable order."
  @spec digest(String.t()) :: String.t()
  def digest(dir) do
    dir
    |> package_files(nil)
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, acc ->
      acc |> :crypto.hash_update(Path.relative_to(path, dir)) |> :crypto.hash_update(<<0>>) |> :crypto.hash_update(File.read!(path))
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # The cache is a map in a persistent_term. Anything else that ever ends up under the key
  # (an older shape) is treated as empty rather than crashing a reader.
  defp cache do
    case :persistent_term.get(@cache, %{}) do
      %{} = map -> map
      _other -> %{}
    end
  end

  defp package_files(dir, entry) do
    for {path, :regular} <- walk(dir), path != entry, do: path
  end

  # A symlink inside a package is content the scan cannot see through, and it can be aimed
  # anywhere. Report it rather than follow it.
  defp structure_scans(dir) do
    findings =
      for {path, :symlink} <- walk(dir) do
        rel = Path.relative_to(path, dir)
        %{severity: :danger, category: "symlink", match: rel, line: 0, file: rel}
      end

    if findings == [], do: [], else: [%{verdict: :danger, findings: findings}]
  end

  @doc """
  Every entry under `dir` as `{path, type}` (`:regular`, `:symlink`, `:directory`, ...),
  depth first, never descending through a symlink. Hidden entries included.
  """
  @spec walk(String.t()) :: [{String.t(), atom()}]
  def walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          case File.lstat(path) do
            {:ok, %{type: :directory}} -> [{path, :directory} | walk(path)]
            {:ok, %{type: type}} -> [{path, type}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end
end
