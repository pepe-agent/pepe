defmodule PepeWeb.AgentSocket do
  @moduledoc """
  WebSocket entry point. Connect at `/socket/websocket` (Phoenix Socket protocol)
  and join the `agent:<agent_name>` (or `agent:default`) topic to chat with
  streaming token deltas.

  Auth mirrors the `/v1` API: open when no tokens are configured, otherwise a valid
  token must be passed as a connect param - `/socket/websocket?token=ctx_...` (browsers
  can't set headers on a WebSocket) - and the connection is tagged with the token's
  scope, which `PepeWeb.AgentChannel` enforces when joining an agent topic.
  """
  use Phoenix.Socket

  alias Pepe.Config

  channel "agent:*", PepeWeb.AgentChannel

  @impl true
  def connect(params, socket, _connect_info) do
    if Config.api_auth_required?() do
      case Config.verify_api_token(params["token"] || "") do
        scope when is_map(scope) -> {:ok, assign(socket, :api_scope, scope)}
        _ -> :error
      end
    else
      {:ok, assign(socket, :api_scope, :unrestricted)}
    end
  end

  @impl true
  def id(_socket), do: nil
end
