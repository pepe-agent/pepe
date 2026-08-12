defmodule Pepe.Skills do
  @moduledoc """
  Skills are on-demand instruction docs (Markdown) that teach the agent a
  *procedure* - e.g. how to install a tool. Built-in skills ship under
  `priv/skills/`; user skills live in `<PEPE_HOME>/skills/` and override a
  built-in of the same name.

  They are NOT loaded into the system prompt in full - only their name + a one-line
  summary are listed there. The agent reads the relevant one with the `skill` tool
  when its topic comes up, keeping context lean.

  A skill is either a loose `<name>.md` file (the common case), or a **package**: a
  `<name>/` directory holding its entry doc (`SKILL.md`, or `<name>.md`, or its first
  `*.md`) plus whatever else it ships alongside, e.g. `scripts/`. A bundled script is
  never copied anywhere on install - it's reached in place, the same way a plugin file
  or the shared workspace already are, via the `skills/<name>/...` path
  `Pepe.Agent.Workspace.resolve/2` understands (so `run_script`'s own `file` argument,
  which resolves through the exact same function, can point straight at it).
  """

  alias Pepe.Config

  @doc "User skills directory."
  def user_dir, do: Path.join(Config.home(), "skills")

  defp builtin_dir, do: Application.app_dir(:pepe, "priv/skills")

  @doc "All skills as `[{name, summary}]` (user skills override built-ins by name)."
  def list do
    (skills_in(builtin_dir()) ++ skills_in(user_dir()))
    |> Map.new()
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Read a skill's full Markdown by name (user dir wins over built-in)."
  def read(name) do
    case read_from(user_dir(), name) do
      {:error, :not_found} -> read_from(builtin_dir(), name)
      result -> result
    end
  end

  @doc """
  The entry doc inside a skill package directory: `SKILL.md` if present, else
  `<dirname>.md`, else its first `*.md` - `nil` if none match. Public so
  `Pepe.Skills.Marketplace` can find the same file when re-scanning an already-installed
  package (`audit/1`) that install-time staging used to decide it was a package.
  """
  @spec package_entry(String.t()) :: String.t() | nil
  def package_entry(dir) do
    skill_md = Path.join(dir, "SKILL.md")
    named = Path.join(dir, Path.basename(dir) <> ".md")

    cond do
      File.regular?(skill_md) -> skill_md
      File.regular?(named) -> named
      true -> Path.wildcard(Path.join(dir, "*.md")) |> List.first()
    end
  end

  defp read_from(dir, name) do
    loose = Path.join(dir, name <> ".md")
    package = Path.join(dir, name)

    cond do
      File.regular?(loose) -> File.read(loose)
      File.dir?(package) -> read_package(package)
      true -> {:error, :not_found}
    end
  end

  defp read_package(dir) do
    case package_entry(dir) do
      nil -> {:error, :not_found}
      file -> File.read(file)
    end
  end

  defp skills_in(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &skill_entry(dir, &1))
      _ -> []
    end
  end

  defp skill_entry(dir, entry) do
    full = Path.join(dir, entry)

    cond do
      String.ends_with?(entry, ".md") and File.regular?(full) ->
        [{String.replace_suffix(entry, ".md", ""), summary(full)}]

      File.dir?(full) ->
        case package_entry(full) do
          nil -> []
          doc -> [{entry, summary(doc)}]
        end

      true ->
        []
    end
  end

  # The first non-empty line is the skill's "use-when" summary.
  defp summary(path) do
    with {:ok, content} <- File.read(path),
         line when is_binary(line) <-
           content |> String.split("\n") |> Enum.find(&(String.trim(&1) != "")) do
      line |> String.replace_prefix("# ", "") |> String.trim() |> String.slice(0, 120)
    else
      _ -> ""
    end
  end
end
