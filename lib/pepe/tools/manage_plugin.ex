defmodule Pepe.Tools.ManagePlugin do
  @moduledoc """
  Let an agent install and manage **plugins** - community-written `.exs` tools/channels -
  from a conversation, instead of requiring an operator to run `mix pepe plugin install`.

  Every install goes through `Pepe.Skills.Sentinel`'s static scan first. A `:danger`
  verdict is always refused here - there is no `force` escape hatch in this tool, on
  purpose: overriding a danger verdict is an operator decision made deliberately at
  the terminal (`mix pepe plugin install SRC --force`), never something an agent talks
  a user into approving mid-conversation. A `:caution` verdict installs but is reported
  so the user sees what the plugin can do.

  This tool is not in the always-safe set: it runs through the ordinary permission
  gate like any other risky action, and a plugin itself runs with full access to the
  app once installed - same trust level as any other dependency.
  """

  @behaviour Pepe.Tools.Tool

  import Pepe.Tools.Tool, only: [function: 3]

  alias Pepe.Plugins
  alias Pepe.Skills.Sentinel

  @impl true
  def name, do: "manage_plugin"

  @impl true
  def spec do
    function(
      "manage_plugin",
      """
      Install and manage community plugins (drop-in Elixir tools/channels, no rebuild). \
      Actions:
      - install: fetch and install a plugin - needs `src` (a local path, a `.tar.gz`, an \
        http(s) URL - a GitHub repo URL is fetched automatically - or a PepeHub \
        reference: a name shaped `@handle/name`, or its page URL from hub.pepe-agent.com). \
        Security-scanned before it's placed; a dangerous verdict is refused (the user can \
        force it themselves via `mix pepe plugin install SRC --force` if they've reviewed \
        it). A PepeHub reference that turns out to be a skill, not a plugin, fails with a \
        message pointing at `manage_skill` instead.
      - scan: security-scan `src` without installing it - use this first to show the \
        user what a plugin does before installing.
      - list: show installed plugins.
      - remove: delete an installed plugin - needs `name`.
      - route_list: show which installed plugins claim their own HTTP route
        (Pepe.PluginRoute) and whether each is enabled. Read-only - enabling or \
        disabling a route is an operator-only decision (`mix pepe plugin route enable`), \
        never something this tool does, since a route (unlike a tool) answers ANY \
        inbound request, not just one this agent's own model decided to make.

      A plugin runs with full access to the app, same trust level as any dependency - \
      always scan or read the source before installing something from an untrusted link.
      """,
      %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ~w(install scan list remove route_list)},
          "src" => %{
            "type" => "string",
            "description" => "Local path, .tar.gz, http(s)/GitHub URL, or PepeHub reference @handle/name (for install/scan)."
          },
          "name" => %{"type" => "string", "description" => "Installed plugin name (for remove)."}
        },
        "required" => ["action"]
      }
    )
  end

  @impl true
  def run(%{"action" => action} = args, ctx) do
    if ctx[:agent], do: dispatch(action, args), else: {:error, "no calling agent in context"}
  end

  def run(_args, _ctx), do: {:error, "manage_plugin needs an `action`"}

  defp dispatch("list", _args), do: {:ok, render_list()}
  defp dispatch("scan", %{"src" => src}), do: scan(src)
  defp dispatch("install", %{"src" => src}), do: install(src)
  defp dispatch("remove", %{"name" => name}), do: remove(name)
  defp dispatch("route_list", _args), do: {:ok, render_routes()}
  defp dispatch("scan", _args), do: {:error, "scan needs `src`"}
  defp dispatch("install", _args), do: {:error, "install needs `src`"}
  defp dispatch("remove", _args), do: {:error, "remove needs `name`"}
  defp dispatch(other, _args), do: {:error, "unknown action: #{other}"}

  defp scan(src) do
    case Plugins.scan(src) do
      {:error, reason} -> {:error, "couldn't scan #{src}: #{inspect(reason)}"}
      report -> {:ok, Sentinel.report(report)}
    end
  end

  defp install(src) do
    case Plugins.install(src) do
      {:ok, name, %{verdict: :safe}} ->
        {:ok, "Installed #{name}. #{Plugins.dir()}\n\nGrant it to an agent's tools with manage_agent."}

      {:ok, name, scan} ->
        {:ok,
         "Installed #{name} (#{Plugins.dir()}), but review this first:\n\n" <>
           Sentinel.report(scan) <>
           "\n\nGrant it to an agent's tools with manage_agent once you're satisfied."}

      {:error, {:unsafe, scan}} ->
        {:error,
         "Refused: the Sentinel flagged #{src} as dangerous.\n\n" <>
           Sentinel.report(scan) <>
           "\n\nIf you've reviewed this yourself and still want it, install it directly " <>
           "with `mix pepe plugin install #{src} --force` - not something to do from chat."}

      {:error, reason} ->
        {:error, "couldn't install #{src}: #{inspect(reason)}"}
    end
  end

  defp remove(name) do
    case Plugins.remove(name) do
      {:ok, name} -> {:ok, "Removed plugin #{name}."}
      {:error, :not_found} -> {:error, "no plugin named #{name}"}
    end
  end

  defp render_list do
    case Plugins.packages() do
      [] ->
        "No plugins installed."

      pkgs ->
        Enum.map_join(pkgs, "\n", &package_line/1)
    end
  end

  defp package_line(p) do
    desc = get_in(p.manifest || %{}, ["description"])
    "• #{p.name} (#{p.kind})#{if desc, do: " - " <> desc, else: ""}"
  end

  defp render_routes do
    case Pepe.PluginRoute.status() do
      [] -> "No installed plugin claims an HTTP route."
      routes -> Enum.map_join(routes, "\n", &route_line/1)
    end
  end

  defp route_line(%{prefix: prefix, collision?: true}),
    do: "• #{prefix} - BLOCKED: more than one installed plugin claims this prefix; rename one's route_prefix/0"

  defp route_line(%{prefix: prefix, enabled?: true}), do: "• #{prefix} - enabled at /plugin-routes/#{prefix}/..."
  defp route_line(%{prefix: prefix}), do: "• #{prefix} - claimed but not enabled"
end
