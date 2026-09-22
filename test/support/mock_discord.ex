defmodule Pepe.Test.MockDiscord do
  @moduledoc """
  A stand-in for Discord over real TCP: the REST calls the bot makes and the gateway
  WebSocket it holds open, so the gateway process is exercised against the wire protocol and
  not against stubs of itself.

    * `GET /gateway/bot` answers where the socket is (or `opts.gateway_status`, to simulate a
      refused token) and tells the test the `authorization` header it was called with.
    * `GET /gw` upgrades to the socket in `Pepe.Test.MockDiscordSocket`.
    * `POST /channels/:id/messages` is where a reply lands: the test is sent
      `{:posted, channel_id, body, headers}`.

  Options: `:test` (pid told about everything), `:interval` (heartbeat interval the socket
  announces, ms), `:ack?` (whether heartbeats are acknowledged).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%{path_info: ["gateway", "bot"]} = conn, opts) do
    send(opts.test, {:gateway_bot, get_req_header(conn, "authorization")})

    case Map.get(opts, :gateway_status, 200) do
      200 ->
        body = %{
          "url" => "ws://#{conn.host}:#{conn.port}/gw",
          "session_start_limit" => %{"remaining" => 999, "total" => 1000, "reset_after" => 1_000}
        }

        json(conn, 200, body)

      status ->
        json(conn, status, %{"message" => "no"})
    end
  end

  def call(%{path_info: ["gw"]} = conn, opts) do
    opts = Map.put(opts, :resume_url, "ws://#{conn.host}:#{conn.port}/gw")
    WebSockAdapter.upgrade(conn, Pepe.Test.MockDiscordSocket, opts, [])
  end

  def call(%{method: "POST", path_info: ["channels", channel, "messages"]} = conn, opts) do
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: %{}, else: Jason.decode!(raw)
    send(opts.test, {:posted, channel, body, conn.req_headers})
    json(conn, 200, %{"id" => "sent"})
  end

  def call(conn, _opts), do: send_resp(conn, 404, "nope")

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
