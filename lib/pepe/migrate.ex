defmodule Pepe.Migrate do
  @moduledoc """
  Import an existing agent-runtime setup into Pepe, so someone already running another
  tool can bring their models and agents over and try Pepe quickly. Each source reads its
  own on-disk config (a different format) and produces a normalized **plan**; this module
  applies the plan to Pepe's config (or reports it, with `dry_run`).

  Supported sources are named in `sources/0`. A source maps to Pepe's schema on a
  best-effort basis and reports what it could not carry over (tools, channels and skills
  that have no direct equivalent), so nothing is silently dropped.
  """

  alias Pepe.Agent.Workspace
  alias Pepe.Config

  @sources %{"openclaw" => Pepe.Migrate.Openclaw, "hermes" => Pepe.Migrate.Hermes}

  @doc "Names of the sources that can be imported."
  def sources, do: @sources |> Map.keys() |> Enum.sort()

  @doc """
  Import from `source`. `opts`: `:from` (the source home dir, else the source default),
  `:dry_run` (report without writing). Returns `{:ok, report}` or `{:error, reason}`.
  """
  def run(source, opts \\ []) do
    with mod when not is_nil(mod) <- @sources[source],
         home <- opts[:from] || mod.default_home(),
         true <- File.dir?(home) do
      plan = mod.plan(home)
      {:ok, apply_plan(plan, source, home, opts[:dry_run] == true)}
    else
      nil -> {:error, {:unknown_source, source}}
      false -> {:error, {:home_not_found, opts[:from] || safe_home(source)}}
    end
  end

  defp safe_home(source), do: (m = @sources[source]) && m.default_home()

  defp apply_plan(plan, source, home, dry_run?) do
    init = %{source: source, home: home, dry_run: dry_run?, applied: [], skipped: []}

    plan
    |> Enum.reduce(init, fn action, acc -> apply_action(action, acc, dry_run?) end)
    |> Map.update!(:applied, &Enum.reverse/1)
    |> Map.update!(:skipped, &Enum.reverse/1)
  end

  defp apply_action(%{kind: :model, model: model}, acc, dry_run?) do
    unless dry_run?, do: Config.put_model(model)
    applied(acc, "model", model.name)
  end

  defp apply_action(%{kind: :agent, agent: agent, files: files}, acc, dry_run?) do
    unless dry_run? do
      Config.put_agent(agent)
      write_files(agent.name, files)
    end

    applied(acc, "agent", agent.name)
  end

  defp apply_action(%{kind: :telegram, token: token} = a, acc, dry_run?) do
    unless dry_run? do
      tg =
        Config.telegram()
        |> Map.put("bot_token", token)
        |> maybe_put("allowed_chats", a[:allowed_chats])

      Config.put_telegram(tg)
    end

    applied(acc, "telegram", "default bot")
  end

  defp apply_action(%{kind: :webhook, slug: slug, entry: entry}, acc, dry_run?) do
    unless dry_run?, do: Config.put_webhook(slug, entry)
    applied(acc, "channel", "#{entry["provider"]}:#{slug}")
  end

  defp apply_action(%{kind: :skill, name: name, content: content}, acc, dry_run?) do
    unless dry_run?, do: write_skill(name, content)
    applied(acc, "skill", name)
  end

  defp apply_action(%{kind: :skip, what: what, reason: reason}, acc, _dry_run?) do
    %{acc | skipped: [%{what: what, reason: reason} | acc.skipped]}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Write a migrated skill as a Pepe skill markdown file, never clobbering an existing one.
  defp write_skill(name, content) do
    dir = Workspace.skills_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}.md")
    unless File.exists?(path), do: File.write!(path, content)
  end

  defp applied(acc, kind, name), do: %{acc | applied: [%{kind: kind, name: name} | acc.applied]}

  # Write per-agent files (SOUL.md, MEMORY.md, skills/...) into the agent's workspace,
  # never clobbering a file that already has content there.
  defp write_files(agent_name, files) do
    dir = Workspace.dir(agent_name)

    for {rel, content} <- files, is_binary(content) and content != "" do
      path = Path.join(dir, rel)
      File.mkdir_p!(Path.dirname(path))
      unless File.exists?(path), do: File.write!(path, content)
    end
  end

  # --- helpers shared by the source modules -----------------------------------------

  @doc """
  Normalize a secret from a source config into a Pepe value: an `${ENV_VAR}` reference is
  kept, a named env source becomes `${ID}`, a raw literal is kept (and flagged). Returns
  `{value, note}` where note is nil or a caution string.
  """
  def secret(nil), do: {nil, nil}

  def secret(%{"source" => "env", "id" => id}) when is_binary(id), do: {"${#{id}}", nil}
  def secret(%{"source" => src}), do: {nil, "secret via #{src} not imported; set it in the model"}

  def secret(value) when is_binary(value) do
    cond do
      value == "" -> {nil, nil}
      Regex.match?(~r/^\$\{[^}]+\}$/, value) -> {value, nil}
      true -> {value, "a raw secret was imported; consider replacing it with a ${ENV_VAR} reference"}
    end
  end

  def secret(_), do: {nil, nil}

  @doc """
  Map source tool ids to Pepe tools: keep the ones that match a real Pepe tool name, and
  fall back to `default` when none match (the source's ids rarely line up).
  """
  def map_tools(names, default) when is_list(names) and names != [] do
    known = MapSet.new(Pepe.Tools.names())

    case Enum.filter(names, &(is_binary(&1) and MapSet.member?(known, &1))) do
      [] -> default
      mapped -> mapped
    end
  end

  def map_tools(_names, default), do: default

  @doc "List the SKILL.md skills under a source directory as `{name, content}` pairs."
  def skills_in(dir) do
    case File.dir?(dir) do
      true ->
        Path.wildcard(Path.join(dir, "**/SKILL.md"))
        |> Enum.map(fn path -> {path |> Path.dirname() |> Path.basename(), read(path)} end)
        |> Enum.reject(fn {_name, content} -> is_nil(content) end)

      false ->
        []
    end
  end

  @doc "Read a file's contents, or nil."
  def read(path) do
    case File.read(path) do
      {:ok, body} -> body
      _ -> nil
    end
  end
end
