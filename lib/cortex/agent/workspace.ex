defmodule Cortex.Agent.Workspace do
  @moduledoc """
  An agent's persistent **workspace** and the cross-agent **shared** space.

  The whole point is *autonomy without hardcoding*: the agent has ordinary file
  tools and a place where files persist, plus a system-prompt note telling it the
  conventions. It then creates and maintains its own knowledge by talking to the
  user — no per-behavior Elixir code.

    * Private workspace: `<CORTEX_HOME>/agents/<name>/` — relative tool paths land
      here and survive across conversations.
    * Shared space: `<CORTEX_HOME>/shared/` — reachable from any agent via a
      `shared/` path prefix.

  A few filenames are **conventions** (`SOUL.md`, `IDENTITY.md`, `USER.md`,
  `AGENTS.md`, `MEMORY.md`, `BOOT.md`): when present their content is injected into
  the system prompt, and the agent is told it may create/update them itself.
  `SOUL.md` (or the config `system_prompt` seed) is the persona.
  """

  use Gettext, backend: Cortex.Gettext

  alias Cortex.Config
  alias Cortex.Config.Agent

  @doc "An agent's private workspace directory."
  def dir(agent_name), do: Path.join([Config.home(), "agents", to_string(agent_name)])

  @doc "The shared, cross-agent directory."
  def shared_dir, do: Path.join(Config.home(), "shared")

  @doc "The drop-in plugins directory (`.exs` tools)."
  def plugins_dir, do: Path.join(Config.home(), "plugins")

  @doc "The user skills directory (`.md` procedure docs)."
  def skills_dir, do: Path.join(Config.home(), "skills")

  @doc "Move an agent's workspace dir when the agent is renamed."
  def rename(old, new) do
    from = dir(old)
    if File.dir?(from), do: File.rename(from, dir(new)), else: :ok
  end

  @doc """
  Resolve a tool path: absolute as-is, `shared/...` into the shared space,
  `plugins/...` into the plugins dir, anything else relative to the agent workspace.
  """
  def resolve(path, agent_name) do
    cond do
      Path.type(path) == :absolute -> path
      path == "shared" -> shared_dir()
      String.starts_with?(path, "shared/") -> Path.join(shared_dir(), strip("shared/", path))
      path == "plugins" -> plugins_dir()
      String.starts_with?(path, "plugins/") -> Path.join(plugins_dir(), strip("plugins/", path))
      path == "skills" -> skills_dir()
      String.starts_with?(path, "skills/") -> Path.join(skills_dir(), strip("skills/", path))
      true -> Path.join(dir(agent_name), path)
    end
  end

  @doc "Resolve a path from a tool `ctx` — uses the bound agent's workspace, else `cwd`."
  def resolve_in_ctx(path, ctx) do
    case ctx[:agent] do
      %{name: name} when is_binary(name) ->
        resolve(path, name)

      _ ->
        if Path.type(path) == :absolute, do: path, else: Path.join(ctx[:cwd] || File.cwd!(), path)
    end
  end

  @doc """
  Build an agent's system prompt. Only the small, stable identity is *loaded*
  (`SOUL.md` persona + `IDENTITY.md`); the rest of the knowledge files are merely
  *listed by name* and read on demand — so a growing `MEMORY.md`/`people.md` never
  bloats the context. A note teaches the agent when to read each.
  """
  def system_prompt(%{name: name, system_prompt: seed}) do
    persona = read(name, "SOUL.md") || persona_seed(seed)
    identity = read(name, "IDENTITY.md") |> labeled("IDENTITY.md")

    [persona, identity, knowledge_index(name), skills_index(), convention_note()]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # With no SOUL.md and only the default seed, the agent has no identity yet — give
  # it onboarding guidance (translated) so it presents as Cortex and offers to set
  # one up. A user-provided seed persona is respected as-is.
  defp persona_seed(seed) do
    if seed in [nil, "", Agent.default_prompt()], do: unnamed_persona(), else: seed
  end

  defp unnamed_persona do
    gettext(
      "You are Cortex, an AI agent, but your identity isn't set up yet — you have no name, persona or defined traits of your own. If the user asks who you are, tell them you're Cortex and that you don't have a name or personality defined yet, then offer to set one up now. If they agree, help them pick a name and a few traits, then save it: write your persona to SOUL.md, and if they choose a name, rename yourself with the rename_agent tool. Always reply in the user's language."
    )
  end

  # List available skills (name + one-line summary). The agent reads the relevant
  # one with the `skill` tool when its topic comes up — not loaded in full here.
  defp skills_index do
    case Cortex.Skills.list() do
      [] ->
        nil

      skills ->
        "## Skills (read the relevant one with the `skill` tool when its topic comes up)\n" <>
          Enum.map_join(skills, "\n", fn {name, summary} -> "- #{name}: #{summary}" end)
    end
  end

  defp labeled(nil, _file), do: nil
  defp labeled(content, file), do: "## #{file}\n#{content}"

  # List (names only) the knowledge files present in the workspace — cheap, and it
  # tells the agent what it can read on demand.
  defp knowledge_index(name) do
    case knowledge_files(name) do
      [] ->
        nil

      files ->
        "## Your knowledge files (read on demand with read_file — NOT preloaded)\n" <>
          Enum.map_join(files, "\n", &"- #{&1}")
    end
  end

  defp knowledge_files(name) do
    case File.ls(dir(name)) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.reject(&(&1 in ["SOUL.md", "IDENTITY.md"]))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp read(name, file) do
    case File.read(Path.join(dir(name), file)) do
      {:ok, content} -> blank_to_nil(String.trim(content))
      _ -> nil
    end
  end

  defp convention_note do
    """
    ## Your workspace
    You have a private, persistent workspace — your own directory. Your file tools
    (read_file, write_file, edit_file, list_dir, move_file) use it for relative
    paths, so files you create there survive across conversations. Paths starting
    with `shared/` read/write a space shared with every other agent; absolute paths
    reach the wider filesystem.

    To stay light on context, your knowledge files are NOT preloaded — read them with
    `read_file` only when the moment calls for it, and update them with write/edit as
    you learn:
    - `people.md` (or similar) — read when the user mentions or asks about a person;
      append who they are when you learn it.
    - `USER.md` — read to recall who you're talking to.
    - `MEMORY.md` — read to recall durable facts/decisions; append lasting learnings.
    - `AGENTS.md` — read for operating rules/house rules.
    - `BOOT.md` — read at the very start of a session for anything to do/recall.
    You may create any other files to organize what you learn; put cross-agent
    knowledge under `shared/`. Only `SOUL.md` (your persona) and `IDENTITY.md` are
    always in context.

    Your *identity* lives in `SOUL.md`/`IDENTITY.md` — edit those to change it. Your
    *handle* is this directory's name; if the user wants you renamed, call
    `rename_agent` (it renames your config entry and moves the directory together).
    """
  end

  defp strip(prefix, path), do: String.replace_prefix(path, prefix, "")
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
