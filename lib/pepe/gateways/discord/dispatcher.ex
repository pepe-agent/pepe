defmodule Pepe.Gateways.Discord.Dispatcher do
  @moduledoc """
  One process per gateway connection, spawned and linked by `Pepe.Gateways.Discord`, that
  calls `Pepe.Webhooks.handle_gateway_event/2` for each message in the order the socket
  received it.

  It exists to keep that call off the socket process. `handle_gateway_event/2` can block for
  seconds - a session lookup, a lane that is itself busy - and the socket process is also the
  one sending heartbeats on a schedule Discord enforces; block it long enough and Discord
  closes the connection as a zombie, which is a worse, self-inflicted version of the slowness
  it was trying to route around. A plain mailbox already gives the ordering guarantee
  (messages a `send/2` puts on one process's queue are handled in the order they arrive), so
  nothing more elaborate is needed to keep two messages from the same channel in order.

  Linked, not supervised on its own: a crash here (though `handle/2` already guards against
  one) takes the connection down with it, and `Pepe.Gateways.Discord`'s own `:transient`
  restart brings both back with a fresh socket, exactly as a crash inside the socket process
  itself already would.
  """

  require Logger

  @doc "Start a dispatcher linked to the caller (the gateway connection process)."
  @spec start_link(String.t()) :: {:ok, pid()}
  def start_link(slug) do
    {:ok, spawn_link(fn -> loop(slug) end)}
  end

  @doc "Queue one gateway payload for this connection's dispatcher, in order."
  @spec dispatch(pid(), map()) :: :ok
  def dispatch(pid, payload) do
    send(pid, {:dispatch, payload})
    :ok
  end

  defp loop(slug) do
    receive do
      {:dispatch, payload} ->
        handle(slug, payload)
        loop(slug)
    end
  end

  defp handle(slug, payload) do
    Pepe.Webhooks.handle_gateway_event(slug, payload)
    :ok
  rescue
    e -> Logger.warning("[discord:#{slug}] could not handle a message: #{Exception.message(e)}")
  catch
    :exit, reason -> Logger.warning("[discord:#{slug}] could not handle a message: #{inspect(reason)}")
  end
end
