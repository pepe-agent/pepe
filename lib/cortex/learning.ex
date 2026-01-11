defmodule Cortex.Learning do
  @moduledoc """
  **TimeLearn** — what an agent has learned, on a timeline.

  Assembles a single list of learning "nodes" from what already lives on disk, so
  the dashboard panel and the `mix cortex timelearn` CLI draw the same data:

    * **skills** — the `.md` procedure docs (built-in in `priv/skills/`, user ones
      in `<CORTEX_HOME>/skills/`), timestamped by file mtime; and
    * **memory** — the entries in the agent's `MEMORY.md`, `USER.md` and `people.md`.

  Skills are shared across agents; memory is per-agent. Nodes are returned newest
  first (like a feed), each with a `:kind`, title, summary, `:source` and `:at`
  (unix seconds).
  """

  alias Cortex.Agent.Workspace
  alias Cortex.Config

  @type node_kind :: :skill | :memory
  @type learning_node :: %{
          kind: node_kind(),
          title: String.t(),
          summary: String.t(),
          source: atom(),
          at: integer()
        }

  @memory_files ~w(MEMORY.md USER.md people.md)

  @doc "The learning timeline for `agent_name` — skills + its memory, newest first."
  @spec timeline(String.t() | nil) :: [learning_node()]
  def timeline(agent_name) do
    (skill_nodes() ++ memory_nodes(agent_name))
    |> Enum.sort_by(& &1.at, :desc)
  end

  @doc "Counts by kind, e.g. `%{skill: 4, memory: 3}`."
  @spec counts(String.t() | nil) :: %{optional(node_kind()) => non_neg_integer()}
  def counts(agent_name) do
    agent_name |> timeline() |> Enum.frequencies_by(& &1.kind)
  end

  ###
  ### skills
  ###

  defp skill_nodes do
    builtin = skill_files(builtin_skills_dir(), :builtin)
    user = skill_files(user_skills_dir(), :user)

    # A user skill overrides the built-in of the same name.
    (builtin ++ user)
    |> Map.new(&{&1.title, &1})
    |> Map.values()
  end

  defp skill_files(dir, source) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn file ->
          path = Path.join(dir, file)

          %{
            kind: :skill,
            title: Path.rootname(file),
            summary: first_line(path),
            source: source,
            at: mtime(path)
          }
        end)

      _ ->
        []
    end
  end

  defp builtin_skills_dir, do: Application.app_dir(:cortex, "priv/skills")
  defp user_skills_dir, do: Path.join(Config.home(), "skills")

  ###
  ### memory
  ###

  defp memory_nodes(nil), do: []

  defp memory_nodes(agent_name) do
    dir = Workspace.dir(agent_name)

    Enum.flat_map(@memory_files, fn file ->
      path = Path.join(dir, file)

      case File.read(path) do
        {:ok, content} ->
          at = mtime(path)

          content
          |> entries()
          |> Enum.map(fn entry ->
            %{kind: :memory, title: file, summary: entry, source: file_source(file), at: at}
          end)

        _ ->
          []
      end
    end)
  end

  # Split a memory file into entries: blank-line-separated blocks, trimmed.
  defp entries(content) do
    content
    |> String.split(~r/\n\s*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp file_source("MEMORY.md"), do: :memory
  defp file_source("USER.md"), do: :user
  defp file_source("people.md"), do: :people
  defp file_source(_other), do: :memory

  ###
  ### helpers
  ###

  defp first_line(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", parts: 2)
        |> List.first()
        |> to_string()
        |> String.trim_leading("# ")
        |> String.trim()

      _ ->
        ""
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end
end
