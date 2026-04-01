defmodule PepeWeb.AgentSocket do
  @moduledoc """
  WebSocket entry point. Connect at `/socket/websocket` (Phoenix Socket protocol)
  and join the `agent:<agent_name>` (or `agent:default`) topic to chat with
  streaming token deltas.

  Auth mirrors the `/v1` API. With tokens configured, a valid token must be passed as a
  connect param, `/socket/websocket?token=ctx_...` (browsers can't set headers on a
  WebSocket), and the connection is tagged with the token's scope, which
  `PepeWeb.AgentChannel` enforces when joining an agent topic. With no tokens
  configured, only same-machine (loopback) connections are accepted; a remote connection
  is refused, so an exposed server is never anonymous.
  """
  use Phoenix.Socket

  alias Pepe.Config
  alias PepeWeb.ApiAuth

  channel "agent:*", PepeWeb.AgentChannel

  @impl true
  def connect(params, socket, connect_info) do
    cond do
      Config.api_auth_required?() ->
        case Config.verify_api_token(params["token"] || "") do
          scope when is_map(scope) -> {:ok, assign(socket, :api_scope, scope)}
          _ -> :error
        end

      loopback?(connect_info) ->
        {:ok, assign(socket, :api_scope, :unrestricted)}

      true ->
        :error
    end
  end

  defp loopback?(%{peer_data: %{address: address}}), do: ApiAuth.loopback?(address)
  defp loopback?(_), do: false

  @impl true
  def id(_socket), do: nil

  @doc """
  Custom `:check_origin` for the `/socket` transport (wired in `lib/pepe_web/endpoint.ex`).

  Phoenix's origin check runs as part of the WebSocket upgrade, *before* `connect/3` -
  it only ever sees the browser's parsed `Origin` header, never the query string, so it
  can't yet know which token (if any) will be presented. This allows an origin that
  either (a) matches this server's own configured host (today's default, unchanged -
  same-host tools/consoles keep working), or (b) matches the `allowed_origin` of *some*
  registered widget token (`Pepe.Config.add_api_token/1`, `kind: "widget"`). That is a
  coarse "is this a known origin at all" gate, not a per-token binding - the bearer
  token itself remains the real per-request authorization boundary, exactly as it is
  for every other token today. A non-browser client sends no `Origin` header at all,
  so Phoenix never calls this for it (see `Phoenix.Socket.Transport.check_origin/5`).
  """
  @spec check_origin?(URI.t()) :: boolean()
  def check_origin?(%URI{host: nil}), do: false

  def check_origin?(%URI{} = uri) do
    same_host?(uri) or registered_widget_origin?(uri)
  end

  defp same_host?(uri) do
    case PepeWeb.Endpoint.config(:url)[:host] do
      host when is_binary(host) -> String.downcase(uri.host) == String.downcase(host)
      _ -> false
    end
  end

  defp registered_widget_origin?(uri) do
    origin = origin_string(uri)

    Enum.any?(Config.api_tokens(), fn t ->
      t["kind"] == "widget" and is_binary(t["allowed_origin"]) and
        normalize_origin(t["allowed_origin"]) == origin
    end)
  end

  defp origin_string(%URI{scheme: scheme, host: host, port: port}) do
    default_port = if scheme == "https", do: 443, else: 80
    suffix = if port in [nil, default_port], do: "", else: ":#{port}"
    "#{scheme}://#{String.downcase(host || "")}#{suffix}"
  end

  defp normalize_origin(str) do
    case URI.parse(str) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) -> origin_string(uri)
      _ -> str
    end
  end
end
