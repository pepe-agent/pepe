defmodule Pepe.Agent.Workspace do
  @moduledoc """
  An agent's persistent **workspace** and the cross-agent **shared** space.

  The whole point is *autonomy without hardcoding*: the agent has ordinary file
  tools and a place where files persist, plus a system-prompt note telling it the
  conventions. It then creates and maintains its own knowledge by talking to the
  user - no per-behavior Elixir code.

    * Private workspace: `<PEPE_HOME>/agents/<name>/` - relative tool paths land
      here and survive across conversations.
    * Shared space: `<PEPE_HOME>/shared/` - reachable from any agent via a
      `shared/` path prefix.

  A few filenames are **conventions** (`SOUL.md`, `IDENTITY.md`, `USER.md`,
  `AGENTS.md`, `MEMORY.md`, `BOOT.md`): when present their content is injected into
  the system prompt, and the agent is told it may create/update them itself.
  `SOUL.md` (or the config `system_prompt` seed) is the persona.
  """

  use Gettext, backend: Pepe.Gettext

  alias Pepe.Config
  alias Pepe.Config.Agent

  @doc """
  An agent's private workspace directory. Root agents live under `agents/<name>`;
  a company agent lives under `companies/<company>/agents/<name>`, so identically
  named agents in different companies never collide and never see each other's files.
  """
  def dir(agent_handle) do
    case Pepe.Company.split(to_string(agent_handle)) do
      {nil, name} -> Path.join([Config.home(), "agents", name])
      {company, name} -> Path.join([Config.home(), "companies", company, "agents", name])
    end
  end

  @doc "The shared, cross-agent directory for the root scope."
  def shared_dir, do: shared_dir(nil)

  @doc """
  The shared directory for an agent's scope. Root shares `shared/`; a company shares
  its own `companies/<company>/shared/` - so `shared/...` paths isolate per company.
  """
  def shared_dir(agent_handle) do
    case Pepe.Company.of(to_string(agent_handle)) do
      nil -> Path.join(Config.home(), "shared")
      company -> Path.join([Config.home(), "companies", company, "shared"])
    end
  end

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
      Path.type(path) == :absolute ->
        path

      path == "shared" ->
        shared_dir(agent_name)

      String.starts_with?(path, "shared/") ->
        Path.join(shared_dir(agent_name), strip("shared/", path))

      path == "plugins" ->
        plugins_dir()

      String.starts_with?(path, "plugins/") ->
        Path.join(plugins_dir(), strip("plugins/", path))

      path == "skills" ->
        skills_dir()

      String.starts_with?(path, "skills/") ->
        Path.join(skills_dir(), strip("skills/", path))

      true ->
        Path.join(dir(agent_name), path)
    end
  end

  @doc "Resolve a path from a tool `ctx` - uses the bound agent's workspace, else `cwd`."
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
  *listed by name* and read on demand - so a growing `MEMORY.md`/`people.md` never
  bloats the context. A note teaches the agent when to read each.
  """
  def system_prompt(%{name: name, system_prompt: seed}) do
    persona = read(name, "SOUL.md") || persona_seed(seed)
    identity = read(name, "IDENTITY.md") |> labeled("IDENTITY.md")

    [persona, identity, now_note(), knowledge_index(name), docs_index(), skills_index(), convention_note()]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  # Ground the agent in the operator's local time so "today"/"tomorrow" and any
  # scheduling are computed in the configured timezone, never assumed to be UTC.
  defp now_note do
    tz = Pepe.Config.default_timezone()

    case DateTime.now(tz) do
      {:ok, dt} ->
        "## Current time\n" <>
          Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S") <>
          " (#{tz}). Treat this as \"now\" for anything time-relative — today, " <>
          "tomorrow, scheduling. Do not assume UTC."

      _ ->
        nil
    end
  end

  # List Pepe's own how-to docs. They are authoritative for how Pepe works - the
  # agent reads the relevant one with the `docs` tool before configuring the system,
  # rather than guessing.
  defp docs_index do
    case Pepe.Docs.list() do
      [] ->
        nil

      docs ->
        "## Pepe docs - authoritative for how Pepe works. Read the relevant one " <>
          "with the `docs` tool BEFORE configuring/operating Pepe (agents, channels, " <>
          "cron, MCP, permissions); don't guess.\n" <>
          Enum.map_join(docs, "\n", fn {name, title} -> "- #{name}: #{title}" end)
    end
  end

  # With no SOUL.md and only the default seed, the agent has no identity yet - give
  # it onboarding guidance (translated) so it presents as Pepe and offers to set
  # one up. A user-provided seed persona is respected as-is.
  defp persona_seed(seed) do
    if seed in [nil, "", Agent.default_prompt()], do: unnamed_persona(), else: seed
  end

  defp unnamed_persona do
    gettext(
      "You are Pepe, an AI agent, but your identity isn't set up yet - you have no name, persona or defined traits of your own. If the user asks who you are, tell them you're Pepe and that you don't have a name or personality defined yet, then offer to set one up now. If they agree, help them pick a name and a few traits, then save it: write your persona to SOUL.md, and if they choose a name, rename yourself with the rename_agent tool. Always reply in the user's language."
    )
  end

  # List available skills (name + one-line summary). The agent reads the relevant
  # one with the `skill` tool when its topic comes up - not loaded in full here.
  defp skills_index do
    case Pepe.Skills.list() do
      [] ->
        nil

      skills ->
        "## Skills (read the relevant one with the `skill` tool when its topic comes up)\n" <>
          Enum.map_join(skills, "\n", fn {name, summary} -> "- #{name}: #{summary}" end)
    end
  end

  defp labeled(nil, _file), do: nil
  defp labeled(content, file), do: "## #{file}\n#{content}"

  # List (names only) the knowledge files present in the workspace - cheap, and it
  # tells the agent what it can read on demand.
  defp knowledge_index(name) do
    case knowledge_files(name) do
      [] ->
        nil

      files ->
        "## Your knowledge files (read on demand with read_file - NOT preloaded)\n" <>
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
    You have a private, persistent workspace - your own directory. Your file tools
    (read_file, write_file, edit_file, list_dir, move_file) use it for relative
    paths, so files you create there survive across conversations. Paths starting
    with `shared/` read/write a space shared with every other agent; absolute paths
    reach the wider filesystem.

    To stay light on context, your knowledge files are NOT preloaded - read them with
    `read_file` only when the moment calls for it, and update them with write/edit as
    you learn:
    - `people.md` (or similar) - read when the user mentions or asks about a person;
      append who they are when you learn it.
    - `USER.md` - read to recall who you're talking to.
    - `MEMORY.md` - read to recall durable facts/decisions; append lasting learnings.
    - `AGENTS.md` - read for operating rules/house rules.
    - `BOOT.md` - read at the very start of a session for anything to do/recall.
    You may create any other files to organize what you learn; put cross-agent
    knowledge under `shared/`. Only `SOUL.md` (your persona) and `IDENTITY.md` are
    always in context.

    Your *identity* lives in `SOUL.md`/`IDENTITY.md` - edit those to change it. Your
    *handle* is this directory's name; if the user wants you renamed, call
    `rename_agent` (it renames your config entry and moves the directory together).

    ## Discretion about your limits
    If something you try turns out not to be available to you (a tool reports it's
    unavailable, or an action is out of your reach), simply tell the user you can't help
    with that - naturally, as if it's just not part of what you do. Do not explain Pepe's
    permission or authority model, do not say you are "not allowed" or "blocked", and do
    not describe capabilities you don't have. A limit you can't act on is not something
    the user needs to hear about.
    """
  end

  defp strip(prefix, path), do: String.replace_prefix(path, prefix, "")
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text
end
