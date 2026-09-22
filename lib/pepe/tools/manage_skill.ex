defmodule Pepe.Tools.ManageSkill do
  @moduledoc """
  Let an agent install and manage **skills** from the marketplace/PepeHub, from a
  conversation, instead of requiring an operator to run `mix pepe skill install`.

  Mirrors `Pepe.Tools.ManagePlugin`'s shape: every install goes through the same static
  Sentinel scan. A `:danger` verdict is always refused here - there is no `force` escape
  hatch in this tool, on purpose: overriding a danger verdict is an operator decision made
  deliberately at the terminal (`mix pepe skill install NAME --force`), never something an
  agent talks a user into approving mid-conversation.

  This is the registry-aware path (`Pepe.Skills.Marketplace`: bundled registry, taps,
  PepeHub) - distinct from the ad-hoc `install-skill` skill, which fetches a single URL by
  hand for a source with no registry entry at all and no update/trust tracking.

  Not in the always-safe set: it runs through the ordinary permission gate like any other
  risky action, and an installed skill is read as untrusted content until reviewed, same
  as `manage_plugin`'s own reasoning.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Skills.Marketplace
  alias Pepe.Skills.Sentinel

  @impl true
  def name, do: "manage_skill"

  @impl true
  def spec do
    function(
      "manage_skill",
      """
      Install and manage skills from the marketplace: the bundled registry, any tap the \
      operator added, or PepeHub (a name shaped `@handle/name`, or its page URL from \
      hub.pepe-agent.com - both resolve the same package). Actions:
      - install: resolve `name` against the registries/PepeHub and install it - or, with \
        `source` given instead, fetch directly from that URL/path (no registry entry \
        needed, always "community" trust). Security-scanned before it's placed; a \
        dangerous verdict is refused (the user can force it themselves via \
        `mix pepe skill install NAME --force` if they've reviewed it).
      - search: search every tap plus the bundled registry for `query` (does not search \
        PepeHub itself - if the user already has a name or a hub.pepe-agent.com link, \
        install it directly).
      - list: show every marketplace-installed skill and where it came from.
      - update: re-fetch `name` from the exact source it was installed from - needs \
        `name`; refuses rather than silently switching if the name now resolves to a \
        different source (a newer PepeHub version, a changed tap entry, ...).
      - remove: delete an installed skill - needs `name`.
      - audit: re-scan an installed skill (or every one, with no `name`) in place.
      - status: every skill that exists, whether it is offered to you and why not when it \
        is not (disabled, another OS, needs a tool you lack), and what each still needs \
        (a missing environment variable or command).
      - validate: check the skill called `name` against the open skill specification and \
        the house rules; the findings say exactly what to fix.
      - preview: look at a skill before installing it (its files, the security scan, the \
        specification check and the opening of its instructions) - takes `name`, or \
        `source` as for install. Installs nothing.
      - check: whether an installed skill has a newer version at its source (`name`, or \
        every one with none). Changes nothing.
      - enable / disable: switch the skill `name` on or off, everywhere or only on the \
        `channel` given (telegram, web, tui, acp, ...).
      - autoload: keep the skill `name` in every agent's context in full (`value` "on") \
        or back to on-demand (`value` "off").
      - config: read (`key` alone) or set (`key` and `value`) a setting a skill declares.

      Trusting a repository's own skills, external skill directories and the inline-shell \
      switch are decisions only a person makes, at the terminal (`mix pepe skill ...`).

      A skill resolved from a tap, an unmarked PepeHub package, or a direct `source`, is \
      "community" trust: reading it with the `skill` tool treats its content as untrusted, \
      the same as a fetched web page, until it has been reviewed.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(install search list update remove audit status validate preview check enable disable autoload config)
          },
          "name" => %{
            "type" => "string",
            "description" =>
              "Skill name, or a PepeHub reference (@handle/name or its page URL) - install/update/remove/audit/validate/preview/check/enable/disable/autoload."
          },
          "source" => %{
            "type" => "string",
            "description" => "Install (or preview) directly from this URL/path instead of resolving `name`."
          },
          "query" => %{"type" => "string", "description" => "Search text (search only)."},
          "channel" => %{"type" => "string", "description" => "Limit enable/disable to one channel (telegram, web, tui, acp, ...)."},
          "key" => %{"type" => "string", "description" => "A setting a skill declares (config only)."},
          "value" => %{"type" => "string", "description" => "The value to set (config), or \"on\"/\"off\" (autoload)."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args, ctx), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "manage_skill needs an `action`"}

  defp dispatch("list", _args, _ctx), do: {:ok, render_list()}
  defp dispatch("search", %{"query" => query}, _ctx), do: {:ok, render_search(query)}
  defp dispatch("search", _args, _ctx), do: {:error, "search needs `query`"}
  defp dispatch("install", %{"name" => name} = args, _ctx), do: install(name, args["source"])
  defp dispatch("install", _args, _ctx), do: {:error, "install needs `name`"}
  defp dispatch("update", %{"name" => name}, _ctx), do: update(name)
  defp dispatch("update", _args, _ctx), do: {:error, "update needs `name`"}
  defp dispatch("remove", %{"name" => name}, _ctx), do: remove(name)
  defp dispatch("remove", _args, _ctx), do: {:error, "remove needs `name`"}
  defp dispatch("audit", args, _ctx), do: {:ok, render_audit(args["name"])}
  defp dispatch("status", _args, ctx), do: {:ok, render_status(ctx)}
  defp dispatch("validate", %{"name" => name}, ctx), do: validate(name, ctx)
  defp dispatch("validate", _args, _ctx), do: {:error, "validate needs `name`"}
  defp dispatch("preview", %{"name" => name} = args, _ctx), do: preview(name, args["source"])
  defp dispatch("preview", _args, _ctx), do: {:error, "preview needs `name`"}
  defp dispatch("check", args, _ctx), do: check(args["name"])
  defp dispatch(action, %{"name" => name} = args, _ctx) when action in ["enable", "disable"], do: switch(action, name, args["channel"])
  defp dispatch(action, _args, _ctx) when action in ["enable", "disable"], do: {:error, "#{action} needs `name`"}
  defp dispatch("autoload", %{"name" => name, "value" => value}, _ctx) when value in ["on", "off"], do: autoload(name, value)
  defp dispatch("autoload", _args, _ctx), do: {:error, "autoload needs `name` and `value` of \"on\" or \"off\""}
  defp dispatch("config", %{"key" => key} = args, _ctx), do: config(key, args["value"])
  defp dispatch("config", _args, _ctx), do: {:error, "config needs `key`"}
  defp dispatch(other, _args, _ctx), do: {:error, "unknown action: #{other}"}

  # -- inspecting and tuning what is already there ------------------------------------------

  defp render_status(ctx) do
    opts = [agent: ctx[:agent], channel: channel(ctx), cwd: ctx[:cwd_override] || ctx[:cwd]]

    lines =
      for %{skill: skill, hidden: hidden, readiness: readiness} <- Pepe.Skills.Catalog.status(opts) do
        reason = if hidden, do: " (not offered: #{hidden_reason(hidden)})", else: ""
        needs = readiness |> Pepe.Skills.Readiness.note() |> then(&if(&1, do: " (#{&1})", else: ""))
        "• #{skill.name} [#{skill.source}]#{reason}#{needs}"
      end

    if lines == [], do: "No skills.", else: Enum.join(Enum.take(lines, 200), "\n")
  end

  defp hidden_reason(:disabled), do: "disabled"
  defp hidden_reason(:platform), do: "for another operating system"
  defp hidden_reason(:environment), do: "for another environment"
  defp hidden_reason(:channel), do: "for other channels"
  defp hidden_reason({:requires_tools, tools}), do: "needs the #{Enum.join(tools, ", ")} tool"
  defp hidden_reason({:fallback_for_tools, tools}), do: "not needed while #{Enum.join(tools, ", ")} is available"

  defp channel(ctx) do
    case ctx[:source] || ctx[:session_key] do
      value when is_binary(value) -> value |> String.split(":", parts: 2) |> hd()
      _ -> nil
    end
  end

  # By name only, never by path: the agent is not asked to read files outside the skills it can see.
  defp validate(name, ctx) do
    case Pepe.Skills.Catalog.find(name, agent: ctx[:agent], channel: channel(ctx), cwd: ctx[:cwd_override] || ctx[:cwd], offer: false) do
      {:ok, skill} ->
        {:ok, report} = Pepe.Skills.Validate.run(skill.dir || skill.entry)
        {:ok, render_validation(name, report)}

      _ ->
        {:error, "no skill named #{name}"}
    end
  end

  defp render_validation(name, %{findings: []}), do: "#{name}: valid, nothing to report."

  defp render_validation(name, report) do
    state = if report.valid?, do: "valid", else: "not valid"
    "#{name}: #{state} (#{report.errors} error(s), #{report.warnings} warning(s))\n" <> Pepe.Skills.Validate.format(report.findings)
  end

  defp preview(name, source) do
    case Marketplace.preview(name, source: source) do
      {:ok, p} -> {:ok, render_preview(p)}
      {:error, :not_found} -> {:error, "no skill named #{name} in any tap, the bundled registry, or PepeHub"}
      {:error, reason} -> {:error, "couldn't fetch #{name}: #{inspect(reason)}"}
    end
  end

  defp render_preview(p) do
    scan = if p.scan.verdict == :safe, do: "safe", else: "#{p.scan.verdict}\n" <> Sentinel.report(p.scan)
    validation = if p.validation == [], do: "no findings", else: "\n" <> Pepe.Skills.Validate.format(p.validation)

    "#{p.name} (#{p.trust_level}) from #{p.source}\nsecurity scan: #{scan}\nfiles: #{Enum.join(p.files, ", ")}\n" <>
      "specification check: #{validation}\n\n--- opening of the instructions ---\n#{p.excerpt}"
  end

  defp check(nil) do
    case Marketplace.check(nil) do
      [] -> {:ok, "No skills installed from a marketplace."}
      results -> {:ok, Enum.map_join(results, "\n", fn {name, result} -> check_line(name, result) end)}
    end
  end

  defp check(name), do: {:ok, check_line(name, Marketplace.check(name))}

  defp check_line(name, {:ok, :current}), do: "• #{name}: up to date"
  defp check_line(name, {:ok, :update_available}), do: "• #{name}: a newer version is available (update it with the update action)"

  defp check_line(name, {:ok, {:source_changed, pinned, now}}),
    do: "• #{name}: now resolves to #{now}, not #{pinned} it was installed from (update would refuse)"

  defp check_line(name, {:error, :not_found}), do: "• #{name}: not installed"
  defp check_line(name, {:error, reason}), do: "• #{name}: couldn't check (#{inspect(reason)})"

  defp switch(action, name, channel) do
    if Pepe.Skills.Catalog.tiers_of(name) == [] do
      {:error, "no skill named #{name}"}
    else
      if action == "disable", do: Pepe.Skills.Settings.disable(name, channel), else: Pepe.Skills.Settings.enable(name, channel)
      {:ok, "#{name} is now #{action}d#{if channel, do: " on #{channel}", else: " everywhere"}."}
    end
  end

  defp autoload(name, "on") do
    if Pepe.Skills.Render.community?(name) do
      {:error, "#{name} came from a community source; its text is not kept in the system prompt."}
    else
      Pepe.Skills.Settings.add_auto_load(name)
      {:ok, "#{name} is kept in context in full from the next conversation."}
    end
  end

  defp autoload(name, "off") do
    Pepe.Skills.Settings.remove_auto_load(name)
    {:ok, "#{name} is back to being read on demand."}
  end

  defp config(key, nil), do: {:ok, "#{key} = #{inspect(Map.get(Pepe.Skills.Settings.config_values(), key))}"}

  defp config(key, value) do
    Pepe.Skills.Settings.put_config(key, value)
    {:ok, "#{key} = #{value}"}
  end

  defp install(name, source) do
    case Marketplace.install(name, source: source) do
      {:ok, installed_name, %{verdict: :safe}} ->
        {:ok, "Installed #{installed_name}.\n\nGrant it to an agent with the skill tool, or read it with `skill`."}

      {:ok, installed_name, scan} ->
        {:ok, "Installed #{installed_name}, but review this first:\n\n" <> Sentinel.report(scan)}

      {:error, {:unsafe, scan}} ->
        {:error,
         "Refused: the Sentinel flagged #{name} as dangerous.\n\n" <>
           Sentinel.report(scan) <>
           "\n\nIf you've reviewed this yourself and still want it, install it directly " <>
           "with `mix pepe skill install #{name} --force` - not something to do from chat."}

      {:error, :not_found} ->
        {:error, "no skill named #{name} in any tap, the bundled registry, or PepeHub"}

      {:error, :ambiguous} ->
        {:error,
         "#{name} doesn't match any skill in that source, and it publishes more than one - " <>
           "refusing to guess which one you meant. Check the source's own listing for the exact name."}

      {:error, reason} ->
        {:error, "couldn't install #{name}: #{inspect(reason)}"}
    end
  end

  defp update(name) do
    case Marketplace.update(name) do
      {:ok, installed_name, %{verdict: :safe}} ->
        {:ok, "Updated #{installed_name}."}

      {:ok, installed_name, scan} ->
        {:ok, "Updated #{installed_name}, but review this first:\n\n" <> Sentinel.report(scan)}

      {:error, {:source_changed, pinned, other}} ->
        {:error,
         "Refused: #{name} now resolves to a different source than it was installed from.\n" <>
           "  installed from: #{pinned}\n  now resolves to: #{other}\n\n" <>
           "If that's expected, the user can replace it explicitly: " <>
           "mix pepe skill install #{name} --source #{other} --force"}

      {:error, :not_found} ->
        {:error, "no installed skill named #{name}"}

      {:error, reason} ->
        {:error, "couldn't update #{name}: #{inspect(reason)}"}
    end
  end

  defp remove(name) do
    case Marketplace.remove(name) do
      {:ok, name} -> {:ok, "Removed skill #{name}."}
      {:error, :not_found} -> {:error, "no installed skill named #{name}"}
    end
  end

  defp render_list do
    case Marketplace.list_installed() do
      [] -> "No skills installed from the marketplace."
      installed -> Enum.map_join(installed, "\n", &installed_line/1)
    end
  end

  defp installed_line(meta), do: "• #{meta["name"]} (#{meta["trust_level"]}, from #{meta["source"]})"

  defp render_search(query) do
    case Marketplace.search(query) do
      [] -> "No skills found matching #{inspect(query)}."
      results -> Enum.map_join(results, "\n", &search_line/1)
    end
  end

  defp search_line(%{name: name, trust_level: trust, source: source}), do: "• #{name} (#{trust}) #{source}"

  defp render_audit(name) do
    name
    |> Marketplace.audit()
    |> Enum.map_join("\n", &audit_line/1)
  end

  defp audit_line(%{name: name, verdict: verdict}), do: "• #{name}: #{verdict}"
end
