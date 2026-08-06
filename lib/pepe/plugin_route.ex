defmodule Pepe.PluginRoute do
  @moduledoc """
  A plugin's own arbitrary HTTP route, mounted at `/plugin-routes/:plugin/*path` - for
  the shapes `Pepe.Webhooks.Provider` can't carry: an OAuth redirect callback that must
  land on Pepe's own public domain, a custom REST/RPC surface, anything a plugin needs to
  answer over HTTP with a request/response shape of its own choosing rather than the
  fixed inbound-event contract every webhook provider shares.

  Unlike a tool or a webhook provider, discovery alone does not expose anything: a
  plugin claims a route by exporting `route_prefix/0` and `call/2`, but nothing answers
  at that path until the operator explicitly enables it
  (`Pepe.Config.enable_http_route_plugin/1`, `mix pepe plugin route enable NAME`). This
  is a second, additive gate beyond installing the plugin itself, because an HTTP route is
  a materially different exposure than a tool call: a tool only ever runs because the
  agent's own model decided to call it, but a route answers *any* inbound request from
  the open internet, unauthenticated by default, the moment it exists - the same reason a
  webhook provider needs an explicit connection created, not just a plugin dropped in
  place. `route_prefix/0` disambiguates one plugin's route from another's, the same way
  `slot/0` disambiguates a slot occupant.

  `call/2` gets the raw `Plug.Conn` (already past the endpoint's own body-parsing) and the
  path segments after the plugin's own prefix, and must return a `Plug.Conn` with a
  response sent - full control, same as any hand-written Plug, because the whole point is
  that Pepe cannot anticipate every shape a plugin's own protocol needs. It is called
  directly, in the request-handling process, guarded only against a crash (a 500, not a
  process-down) - there's no isolation `Task`/timeout the way `Pepe.Slots.Guard` gives a
  slot occupant, because a Plug is expected to own its own conn lifecycle (streaming a
  response, holding a long-poll open) in ways a bounded-timeout wrapper would break.
  """

  @callback route_prefix() :: String.t()
  @callback call(conn :: Plug.Conn.t(), path :: [String.t()]) :: Plug.Conn.t()

  require Logger

  @doc """
  Every distinct route prefix any installed plugin claims, as `%{prefix, module,
  enabled?, collision?}` - for the dashboard/`mix pepe plugin route list`. `enabled?`
  reflects `Pepe.Config.http_route_plugins/0`; a plugin can claim a prefix (export the
  callbacks) without ever being enabled, and this lists it either way so the operator can
  see what's available to turn on.

  `collision?` is true when more than one installed plugin claims the same `prefix` -
  `module` is `nil` in that case, and `occupant/1` refuses to dispatch to either one
  (logged) rather than picking a winner by file-sort order. Without this, a SECOND
  plugin installed later, claiming an already-enabled, trusted plugin's own prefix (an
  OAuth callback route, say), would silently start receiving that route's traffic - a
  route hijack an operator has no reason to expect from merely installing an unrelated
  plugin.
  """
  @spec status() :: [%{prefix: String.t(), module: module() | nil, enabled?: boolean(), collision?: boolean()}]
  def status do
    enabled = Pepe.Config.http_route_plugins()

    [{:route_prefix, 0}, {:call, 2}]
    |> Pepe.Plugins.implementing()
    |> Enum.flat_map(&candidate/1)
    |> Enum.group_by(& &1.prefix)
    |> Enum.map(fn {prefix, claimants} -> entry(prefix, claimants, enabled) end)
    |> Enum.sort_by(& &1.prefix)
  end

  defp candidate(mod) do
    case Pepe.Plugins.safe_call(mod, :route_prefix, []) do
      {:ok, prefix} when is_binary(prefix) -> [%{prefix: prefix, module: mod}]
      _ -> []
    end
  end

  defp entry(prefix, [%{module: mod}], enabled), do: %{prefix: prefix, module: mod, enabled?: prefix in enabled, collision?: false}

  defp entry(prefix, claimants, enabled) do
    mods = Enum.map(claimants, & &1.module)

    Logger.error(
      "[plugin_route] #{length(mods)} installed plugins all claim the route prefix #{inspect(prefix)} (#{inspect(mods)}) - " <>
        "refusing to dispatch to any of them until this is resolved (rename one's route_prefix/0)"
    )

    %{prefix: prefix, module: nil, enabled?: prefix in enabled, collision?: true}
  end

  @doc """
  The enabled, unambiguous plugin module claiming `prefix`, or `nil` - not enabled, not
  claimed at all, or claimed by more than one installed plugin at once (see `status/0`'s
  `collision?`).
  """
  @spec occupant(String.t()) :: module() | nil
  def occupant(prefix) do
    case Enum.find(status(), &(&1.prefix == prefix)) do
      %{module: mod, enabled?: true, collision?: false} when not is_nil(mod) -> mod
      _ -> nil
    end
  end
end
