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

      A skill resolved from a tap, an unmarked PepeHub package, or a direct `source`, is \
      "community" trust: reading it with the `skill` tool treats its content as untrusted, \
      the same as a fetched web page, until it has been reviewed.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(install search list update remove audit)},
          "name" => %{
            "type" => "string",
            "description" => "Skill name, or a PepeHub reference (@handle/name or its page URL) - install/update/remove/audit."
          },
          "source" => %{
            "type" => "string",
            "description" => "Install directly from this URL/path instead of resolving `name` (install only)."
          },
          "query" => %{"type" => "string", "description" => "Search text (search only)."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "manage_skill needs an `action`"}

  defp dispatch("list", _args), do: {:ok, render_list()}
  defp dispatch("search", %{"query" => query}), do: {:ok, render_search(query)}
  defp dispatch("search", _args), do: {:error, "search needs `query`"}
  defp dispatch("install", %{"name" => name} = args), do: install(name, args["source"])
  defp dispatch("install", _args), do: {:error, "install needs `name`"}
  defp dispatch("update", %{"name" => name}), do: update(name)
  defp dispatch("update", _args), do: {:error, "update needs `name`"}
  defp dispatch("remove", %{"name" => name}), do: remove(name)
  defp dispatch("remove", _args), do: {:error, "remove needs `name`"}
  defp dispatch("audit", args), do: {:ok, render_audit(args["name"])}
  defp dispatch(other, _args), do: {:error, "unknown action: #{other}"}

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
