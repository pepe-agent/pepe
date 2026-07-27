defmodule Pepe.MCP.OAuthTest do
  @moduledoc """
  The MCP-specific half of the OAuth flow: finding an authorization server nobody told us
  about, getting a client identity from it, and keeping the resulting grant fresh. The
  browser dance itself belongs to `Pepe.OAuth` and is covered by its own test.
  """
  use ExUnit.Case, async: false

  alias Pepe.MCP.Credential
  alias Pepe.MCP.OAuth

  defmodule AuthServer do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: Enum.into(opts, %{})

    @impl true
    def call(conn, opts) do
      case conn.request_path do
        "/.well-known/oauth-protected-resource" ->
          if opts[:publish_resource] == false do
            send_resp(conn, 404, "")
          else
            json(conn, %{"authorization_servers" => [base(conn)]})
          end

        "/.well-known/oauth-authorization-server" ->
          json(conn, %{
            "issuer" => base(conn),
            "authorization_endpoint" => base(conn) <> "/authorize",
            "token_endpoint" => base(conn) <> "/token",
            "registration_endpoint" => base(conn) <> "/register",
            "scopes_supported" => ["mcp:read", "mcp:write"]
          })

        "/register" ->
          {:ok, body, conn} = read_body(conn)
          send(opts.test, {:registration, Jason.decode!(body)})
          json(conn, %{"client_id" => "client-123"})

        "/token" ->
          {:ok, body, conn} = read_body(conn)
          send(opts.test, {:token_request, URI.decode_query(body)})

          json(conn, %{
            "access_token" => "fresh-access",
            "refresh_token" => "fresh-refresh",
            "expires_in" => 3600
          })

        _ ->
          send_resp(conn, 404, "")
      end
    end

    defp base(conn), do: "http://127.0.0.1:#{conn.port}"

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  defp start_auth_server(opts \\ []) do
    {:ok, server} =
      Bandit.start_link(
        plug: {AuthServer, Keyword.merge([test: self()], opts)},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  describe "discovery" do
    test "follows the protected-resource document to the authorization server" do
      base = start_auth_server()

      assert {:ok, meta} = OAuth.discover(base <> "/mcp")
      assert meta.authorize_url == base <> "/authorize"
      assert meta.token_url == base <> "/token"
      assert meta.registration_url == base <> "/register"
      assert meta.scopes == ["mcp:read", "mcp:write"]
    end

    test "falls back to the server's own origin when it publishes no resource document" do
      base = start_auth_server(publish_resource: false)

      # A small self-hosted deployment is usually its own issuer, so a missing RFC 9728
      # document is not a failure - it just means "look here".
      assert {:ok, meta} = OAuth.discover(base <> "/mcp")
      assert meta.token_url == base <> "/token"
    end

    test "reports a server with no OAuth metadata at all" do
      {:ok, server} =
        Bandit.start_link(
          plug: {Pepe.Test.MockMCP, mode: :streamable},
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

      assert {:error, {:mcp_no_oauth_metadata, _issuer, _reason}} =
               OAuth.discover("http://127.0.0.1:#{port}/mcp")
    end
  end

  describe "challenge" do
    test "pulls the resource metadata URL out of a 401" do
      resp =
        Req.Response.new(status: 401)
        |> Req.Response.put_header(
          "www-authenticate",
          ~s(Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource")
        )

      assert OAuth.challenge(resp) ==
               "https://mcp.example.com/.well-known/oauth-protected-resource"
    end

    test "is nil when the challenge names no metadata" do
      resp = Req.Response.new(status: 401) |> Req.Response.put_header("www-authenticate", "Bearer")
      assert OAuth.challenge(resp) == nil
    end
  end

  describe "stored grants" do
    setup do
      Pepe.RepoSetup.start!()
      :ok
    end

    test "no grant is not an error - most servers use a static key and never sign in" do
      assert {:error, :none} = OAuth.token("never-signed-in")
    end

    test "an unexpired token is handed back as-is" do
      put_credential("memclaw", %{
        access_token: "still-good",
        expires_at: System.os_time(:second) + 3600
      })

      assert {:ok, "still-good"} = OAuth.token("memclaw")
    end

    test "an expired token is refreshed, stored, and the new one returned" do
      base = start_auth_server()

      put_credential("memclaw", %{
        access_token: "stale",
        refresh_token: "the-refresh-token",
        expires_at: System.os_time(:second) - 10,
        token_url: base <> "/token",
        client_id: "client-123",
        resource: "https://mcp.example.com/mcp"
      })

      assert {:ok, "fresh-access"} = OAuth.token("memclaw")

      assert_receive {:token_request, params}
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "the-refresh-token"
      # RFC 8707: the refreshed token stays bound to the same MCP server.
      assert params["resource"] == "https://mcp.example.com/mcp"

      # Persisted, so the next call doesn't refresh again.
      assert %Credential{access_token: "fresh-access", refresh_token: "fresh-refresh"} =
               OAuth.credential("memclaw")
    end

    test "a failed refresh keeps the old token rather than forcing a re-login" do
      put_credential("memclaw", %{
        access_token: "stale-but-maybe-fine",
        refresh_token: "whatever",
        expires_at: System.os_time(:second) - 10,
        # Nothing listening: the refresh cannot succeed.
        token_url: "http://127.0.0.1:1/token",
        client_id: "client-123"
      })

      assert {:ok, "stale-but-maybe-fine"} = OAuth.token("memclaw")
    end

    test "logout forgets the grant" do
      put_credential("memclaw", %{access_token: "x", expires_at: System.os_time(:second) + 60})
      assert :ok = OAuth.logout("memclaw")
      assert OAuth.credential("memclaw") == nil
      assert {:error, :none} = OAuth.token("memclaw")
    end

    defp put_credential(server, attrs) do
      %Credential{}
      |> Credential.changeset(Map.merge(%{server: server}, attrs))
      |> Pepe.Repo.insert!(on_conflict: :replace_all, conflict_target: :server)
    end
  end
end
