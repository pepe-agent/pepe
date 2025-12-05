defmodule CortexWeb.AgentSocket do
  @moduledoc """
  WebSocket entry point. Connect at `/socket/websocket` (Phoenix Socket protocol)
  and join the `agent:<agent_name>` (or `agent:default`) topic to chat with
  streaming token deltas.
  """
  use Phoenix.Socket

  channel "agent:*", CortexWeb.AgentChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
