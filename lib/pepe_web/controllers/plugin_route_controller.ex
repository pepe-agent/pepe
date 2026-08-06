defmodule PepeWeb.PluginRouteController do
  @moduledoc """
  Dispatches `/plugin-routes/:plugin/*path` to whichever plugin currently claims and is
  enabled for `:plugin` (see `Pepe.PluginRoute`). Not enabled - unclaimed, disabled, or
  never installed - all read the same from the outside: a plain 404, never a hint about
  which of the three it was.
  """
  use PepeWeb, :controller

  require Logger

  # The standard Plug idiom (see Plug.ErrorHandler/Plug.Debugger) for "did the crashed
  # call already send a response?". `conn` here is the pre-call value - Elixir's
  # immutability means the plugin's own locally-reassigned, already-`:sent` conn is lost
  # the instant it raises, so `conn.state` on the copy we're still holding is USELESS for
  # this (always its original pre-call value, whatever that response actually happened).
  # The real signal is this message: a Plug adapter (Bandit, Cowboy, Plug.Test) sends
  # `{:plug_conn, :sent}` to the conn's OWNING PROCESS - not through the conn struct at
  # all - the instant it actually writes a response. Draining it (and re-sending it, the
  # same as Plug.ErrorHandler does, in case something else downstream still wants to see
  # it) is the only reliable way to know.
  @already_sent {:plug_conn, :sent}

  def dispatch(conn, %{"plugin" => plugin} = params) do
    path = params["path"] || []

    case Pepe.PluginRoute.occupant(plugin) do
      nil ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "not found")

      mod ->
        run(mod, conn, path)
    end
  end

  defp run(mod, conn, path) do
    mod.call(conn, path)
  rescue
    e -> crash_response(conn, mod, path, Exception.message(e), :error, e, __STACKTRACE__)
  catch
    kind, reason -> crash_response(conn, mod, path, "#{kind}: #{inspect(reason)}", kind, reason, __STACKTRACE__)
  end

  # A crashing plugin may have already sent (or started streaming) a response before it
  # raised - answering 500 on top of that would be a second response on the same
  # connection (corruption, or a smuggled response on a keep-alive connection). There is
  # no conn to safely return in that case either (see the `@already_sent` comment above -
  # the one we're holding is stale, not the plugin's own already-`:sent` copy), so this
  # re-raises instead, exactly as `Plug.ErrorHandler` does: the crash still happens, but
  # now *after* the real response already went out, which is a supervisor-level concern
  # (Bandit's own per-connection process logs it and moves on) rather than a second,
  # corrupting response to the client.
  defp crash_response(conn, mod, path, detail, kind, reason, stack) do
    Logger.error("[plugin_route] #{inspect(mod)} crashed handling #{inspect(path)}: #{detail}")

    receive do
      @already_sent ->
        send(self(), @already_sent)
        :erlang.raise(kind, reason, stack)
    after
      0 -> conn |> put_resp_content_type("text/plain") |> send_resp(500, "internal error")
    end
  end
end
