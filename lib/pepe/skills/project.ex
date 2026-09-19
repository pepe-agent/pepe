defmodule Pepe.Skills.Project do
  @moduledoc """
  Skills that live inside a repository: `<repo>/.pepe/skills/` and the cross-tool
  `<repo>/.agents/skills/` convention.

  A repository's skills are instructions the agent will follow, written by whoever can
  push to that repository - which is a prompt-injection vector the moment an agent is
  pointed at a clone it does not own. So they load only for a repository the operator has
  explicitly trusted (`mix pepe skill trust`), and even then each one is scanned: a skill
  whose scan comes back `:danger` is quarantined, meaning it is excluded from the index,
  from reads and from slash commands, exactly as if it were absent. Trust is a decision
  about a repository made once; the content underneath it keeps changing with every pull,
  which is why the scan runs on the content and not on the decision.
  """

  alias Pepe.Skills.Guard
  alias Pepe.Skills.Sentinel
  alias Pepe.Skills.Settings

  @subdirs [".pepe/skills", ".agents/skills"]
  @max_depth 64

  @doc "The nearest ancestor of `cwd` that holds a `.git`, or `nil` (a repository at $HOME is not a project)."
  @spec root(String.t() | nil) :: String.t() | nil
  def root(nil), do: nil

  def root(cwd) do
    home = System.user_home() |> maybe_expand()
    find_root(Path.expand(cwd), home, 0)
  end

  defp maybe_expand(nil), do: nil
  defp maybe_expand(path), do: Path.expand(path)

  defp find_root(_dir, _home, depth) when depth > @max_depth, do: nil

  defp find_root(dir, home, depth) do
    cond do
      File.exists?(Path.join(dir, ".git")) -> if dir == home, do: nil, else: dir
      Path.dirname(dir) == dir -> nil
      true -> find_root(Path.dirname(dir), home, depth + 1)
    end
  end

  @doc "Whether `root` is a trusted repository."
  @spec trusted?(String.t()) :: boolean()
  def trusted?(root), do: Path.expand(root) in Settings.trusted_project_dirs()

  @doc "The skill directories of the trusted project around `cwd` (empty when there is none, or it is not trusted)."
  @spec dirs(String.t() | nil) :: [String.t()]
  def dirs(cwd) do
    case root(cwd) do
      nil -> []
      root -> if trusted?(root), do: existing_dirs(root), else: []
    end
  end

  @doc "`{root, skill_count}` when the project around `cwd` ships skills but is not trusted, else `nil`."
  @spec untrusted(String.t() | nil) :: {String.t(), pos_integer()} | nil
  def untrusted(cwd) do
    with root when is_binary(root) <- root(cwd),
         false <- trusted?(root),
         count when count > 0 <- root |> existing_dirs() |> Enum.map(&count_skills/1) |> Enum.sum() do
      {root, count}
    else
      _ -> nil
    end
  end

  defp existing_dirs(root), do: for(sub <- @subdirs, dir = Path.join(root, sub), File.dir?(dir), do: dir)

  defp count_skills(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.count(entries, &(String.ends_with?(&1, ".md") or File.dir?(Path.join(dir, &1))))
      _ -> 0
    end
  end

  @doc "Trust the repository around `path` (or `path` itself when it is not inside one). Returns the root trusted."
  @spec trust(String.t()) :: String.t()
  def trust(path) do
    root = root(path) || Path.expand(path)
    Settings.trust_project(root)
    root
  end

  @doc "Stop trusting the repository around `path`. Returns the root."
  @spec untrust(String.t()) :: String.t()
  def untrust(path) do
    root = root(path) || Path.expand(path)
    Settings.untrust_project(root)
    root
  end

  @doc """
  Whether a project skill (a package directory or a loose doc) must not load: its scan came
  back `:danger`. Fails closed: content that cannot be read is quarantined.
  """
  @spec quarantined?(String.t()) :: boolean()
  def quarantined?(path) do
    if File.dir?(path) do
      Guard.scan_package_cached(path).verdict == :danger
    else
      path |> File.read!() |> Sentinel.scan() |> Map.fetch!(:verdict) == :danger
    end
  rescue
    _ -> true
  end
end
