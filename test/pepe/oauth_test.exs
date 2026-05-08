defmodule Pepe.OAuthTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.OAuth

  # The provider's token endpoint. Every request is forwarded to the test (body and
  # content-type included), so a test can assert on what was actually sent, and on
  # what was *not* sent at all - a token that is still fresh must never reach here.
  # `:oauth_token_mode` swaps the canned 200 body for a 400, to drive the error paths.
  defmodule TokenPlug do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json, :urlencoded], json_decoder: Jason)
    plug(:dispatch)

    post "/token" do
      type = conn |> Plug.Conn.get_req_header("content-type") |> List.first() |> to_string()
      send(Agent.get(:oauth_token_pid, & &1), {:token_request, type, conn.body_params})

      case Agent.get(:oauth_token_mode, & &1) do
        # 400, not 5xx: Req does not burn three retries and seven seconds of backoff
        # on it, which the suite would feel, and it fails the exchange just the same.
        :fail ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(400, ~s({"error":"invalid_grant"}))

        body ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end
    end
  end

  test "pkce challenge is the unpadded base64url SHA-256 of the verifier" do
    {verifier, challenge} = OAuth.pkce()

    assert challenge == Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    refute String.contains?(challenge, "=")
    refute String.contains?(verifier, "=")
  end

  test "random_state is unique and hex" do
    a = OAuth.random_state()
    b = OAuth.random_state()

    assert a =~ ~r/^[0-9a-f]+$/
    assert a != b
  end

  test "authorize_url carries the standard + provider-specific params" do
    flow = %{
      authorize_url: "https://auth.example.com/oauth/authorize",
      client_id: "client-123",
      redirect_uri: "http://localhost:1455/auth/callback",
      scope: "openid profile",
      extra_params: %{"originator" => "pepe"}
    }

    url = OAuth.authorize_url(flow, "the-challenge", "the-state")
    %URI{query: query} = URI.parse(url)
    params = URI.decode_query(query)

    assert String.starts_with?(url, "https://auth.example.com/oauth/authorize?")
    assert params["response_type"] == "code"
    assert params["client_id"] == "client-123"
    assert params["redirect_uri"] == "http://localhost:1455/auth/callback"
    assert params["scope"] == "openid profile"
    assert params["code_challenge"] == "the-challenge"
    assert params["code_challenge_method"] == "S256"
    assert params["state"] == "the-state"
    assert params["originator"] == "pepe"
  end

  describe "callback server" do
    setup do
      {:ok, _} = Application.ensure_all_started(:bandit)
      {:ok, _} = Application.ensure_all_started(:req)
      :ok
    end

    test "hands the authorization code back to the owner on a valid state" do
      ref = make_ref()

      {:ok, server} =
        Bandit.start_link(
          plug: {Pepe.OAuth.Callback, owner: self(), ref: ref, state: "st-ok", path: "/auth/callback"},
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: 0
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      Req.get!("http://127.0.0.1:#{port}/auth/callback?code=the-code&state=st-ok")

      assert_receive {:oauth_code, ^ref, "the-code"}, 2_000
      Process.exit(server, :normal)
    end

    test "reports an error when the state does not match" do
      ref = make_ref()

      {:ok, server} =
        Bandit.start_link(
          plug: {Pepe.OAuth.Callback, owner: self(), ref: ref, state: "expected", path: "/auth/callback"},
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: 0
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      Req.get!("http://127.0.0.1:#{port}/auth/callback?code=x&state=tampered")

      assert_receive {:oauth_error, ^ref, :state_mismatch}, 2_000
      Process.exit(server, :normal)
    end
  end

  test "extract_code accepts a bare code or a full redirect URL" do
    assert OAuth.extract_code("abc123") == "abc123"
    assert OAuth.extract_code("http://localhost:1455/auth/callback?code=xyz&state=s") == "xyz"
  end

  test "begin/2 returns a live session with the authorize link, and cancel stops it" do
    flow = %{
      authorize_url: "https://auth.example.com/authorize",
      token_url: "https://auth.example.com/token",
      client_id: "c-1",
      redirect_uri: "http://localhost:14559/cb",
      scope: "openid",
      callback_port: 14_559,
      callback_path: "/cb"
    }

    assert {:ok, session} = OAuth.begin(flow)
    assert String.starts_with?(session.url, "https://auth.example.com/authorize?")
    assert is_reference(session.ref)
    assert OAuth.cancel(session)
  end

  test "subscription_connection builds a model from a method spec + tokens" do
    method = %{
      base_url: "https://chatgpt.com/backend-api/codex",
      api: "openai-responses",
      models: ["gpt-5.5", "gpt-5.4"],
      oauth_flow: %{token_url: "https://auth.openai.com/oauth/token", client_id: "app_x", token_content_type: :form}
    }

    model = OAuth.subscription_connection("openai", method, "openai", %{access: "acc", refresh: "ref", expires_at: 123})

    assert model.name == "openai"
    assert model.base_url == "https://chatgpt.com/backend-api/codex"
    assert model.api == "openai-responses"
    assert model.api_key == "acc"
    assert model.model == "gpt-5.5"
    assert model.oauth["provider"] == "openai"
    assert model.oauth["refresh"] == "ref"
    assert model.oauth["token_content_type"] == "form"
  end

  test "Providers.subscription_methods lists the OAuth providers" do
    methods = Pepe.Providers.subscription_methods()
    providers = Enum.map(methods, & &1.provider)

    assert "openai" in providers
    assert "anthropic" in providers
    assert Enum.all?(methods, &is_map(&1.method.oauth_flow))
  end

  describe "reconnect/1" do
    setup do
      home = Path.join(System.tmp_dir!(), "pepe_oauth_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      prev = System.get_env("PEPE_HOME")
      System.put_env("PEPE_HOME", home)

      on_exit(fn ->
        if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
        File.rm_rf(home)
      end)

      :ok
    end

    test "unknown connection name" do
      assert {:error, :not_found} = OAuth.reconnect("ghost")
    end

    test "a plain API-key connection has nothing to reconnect" do
      Config.put_model(%Model{name: "openrouter", base_url: "https://openrouter.ai/api/v1", api_key: "sk-x", model: "gpt"})

      assert {:error, :not_oauth} = OAuth.reconnect("openrouter")
    end

    test "an oauth connection whose provider no longer exists is refused cleanly" do
      Config.put_model(%Model{
        name: "stale",
        base_url: "https://example.com",
        api_key: "old-token",
        model: "gpt",
        oauth: %{"provider" => "no-such-provider", "refresh" => "r", "expires_at" => 0}
      })

      assert {:error, :unsupported_provider} = OAuth.reconnect("stale")
      # Refused before touching anything - the stale connection is untouched.
      assert Config.get_model("stale").api_key == "old-token"
    end
  end

  describe "against a real token endpoint" do
    setup do
      home = Path.join(System.tmp_dir!(), "pepe_oauth_tok_#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      prev = System.get_env("PEPE_HOME")
      System.put_env("PEPE_HOME", home)

      test_pid = self()
      {:ok, _} = Agent.start_link(fn -> test_pid end, name: :oauth_token_pid)

      {:ok, _} =
        Agent.start_link(
          fn -> %{"access_token" => "fresh-access", "refresh_token" => "fresh-refresh", "expires_in" => 3600} end,
          name: :oauth_token_mode
        )

      {:ok, server} = Bandit.start_link(plug: TokenPlug, port: 0, scheme: :http, startup_log: false)
      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

      on_exit(fn ->
        Process.exit(server, :normal)
        if prev, do: System.put_env("PEPE_HOME", prev), else: System.delete_env("PEPE_HOME")
        File.rm_rf(home)
      end)

      {:ok, token_url: "http://127.0.0.1:#{port}/token"}
    end

    defp answers(body), do: Agent.update(:oauth_token_mode, fn _ -> body end)

    defp flow(token_url, extra \\ %{}) do
      Map.merge(
        %{
          authorize_url: "https://auth.example.com/authorize",
          token_url: token_url,
          client_id: "c-1",
          redirect_uri: "http://localhost:1455/cb",
          scope: "openid",
          # An ephemeral port: the exchange is what's under test here, not the loopback
          # capture, so no test needs to fight another for a fixed one.
          callback_port: 0,
          callback_path: "/cb"
        },
        extra
      )
    end

    # An oauth connection whose access token expired `ago` seconds back (negative =
    # still valid for that long).
    defp expiring_model(token_url, ago) do
      %Model{
        name: "sub",
        base_url: "https://api.example.com",
        api_key: "old-access",
        model: "gpt",
        oauth: %{
          "provider" => "openai",
          "refresh" => "old-refresh",
          "expires_at" => System.os_time(:second) - ago,
          "token_url" => token_url,
          "client_id" => "c-1",
          "token_content_type" => "form"
        }
      }
    end

    test "finish/2 exchanges the code for tokens, form-encoded by default", %{token_url: url} do
      {:ok, session} = OAuth.begin(flow(url))

      assert {:ok, tokens} = OAuth.finish(session, "the-code")

      assert_receive {:token_request, type, body}
      assert type =~ "application/x-www-form-urlencoded"
      assert body["grant_type"] == "authorization_code"
      assert body["code"] == "the-code"
      assert body["client_id"] == "c-1"
      assert body["redirect_uri"] == "http://localhost:1455/cb"
      # The PKCE verifier from `begin/2` is what proves this is the same client that
      # asked for the code - without it the exchange is replayable by anyone.
      assert body["code_verifier"] == session.verifier
      # A provider that doesn't ask for `state` in the exchange must not get one.
      refute Map.has_key?(body, "state")

      assert tokens.access == "fresh-access"
      assert tokens.refresh == "fresh-refresh"
      assert_in_delta tokens.expires_at, System.os_time(:second) + 3600, 5
    end

    test "a provider that wants JSON gets JSON, with the state included", %{token_url: url} do
      {:ok, session} = OAuth.begin(flow(url, %{token_content_type: :json, token_includes_state: true}))

      assert {:ok, _tokens} = OAuth.finish(session, "the-code")

      assert_receive {:token_request, type, body}
      assert type =~ "application/json"
      assert body["state"] == session.state
    end

    test "a rejected code is reported, not raised", %{token_url: url} do
      answers(:fail)
      {:ok, session} = OAuth.begin(flow(url))

      assert {:error, {:token_http, 400, body}} = OAuth.finish(session, "bad-code")
      assert body["error"] == "invalid_grant"
    end

    test "expires_in arrives as a string from some providers and still becomes a timestamp", %{token_url: url} do
      answers(%{"access_token" => "a", "refresh_token" => "r", "expires_in" => "7200"})
      {:ok, session} = OAuth.begin(flow(url))

      assert {:ok, tokens} = OAuth.finish(session, "c")
      assert_in_delta tokens.expires_at, System.os_time(:second) + 7200, 5
    end

    test "a provider that sends no expiry leaves expires_at unknown", %{token_url: url} do
      answers(%{"access_token" => "a", "refresh_token" => "r"})
      {:ok, session} = OAuth.begin(flow(url))

      assert {:ok, %{expires_at: nil}} = OAuth.finish(session, "c")
    end

    test "ensure_fresh refreshes an expired token and persists the new one", %{token_url: url} do
      Config.put_model(expiring_model(url, 10))

      fresh = OAuth.ensure_fresh(Config.get_model("sub"))

      assert_receive {:token_request, _type, body}
      assert body["grant_type"] == "refresh_token"
      assert body["refresh_token"] == "old-refresh"

      assert fresh.api_key == "fresh-access"
      assert fresh.oauth["refresh"] == "fresh-refresh"
      # Persisted, not just returned: the next process to load the connection must not
      # go back to hammering the provider with the dead token.
      assert Config.get_model("sub").api_key == "fresh-access"
    end

    test "a token inside the refresh margin is refreshed before it can expire mid-call", %{token_url: url} do
      # Still valid, but only for 30s - a long turn would die holding it.
      Config.put_model(expiring_model(url, -30))

      assert OAuth.ensure_fresh(Config.get_model("sub")).api_key == "fresh-access"
      assert_receive {:token_request, _type, _body}
    end

    test "a still-valid token is not refreshed", %{token_url: url} do
      Config.put_model(expiring_model(url, -3600))

      assert OAuth.ensure_fresh(Config.get_model("sub")).api_key == "old-access"
      refute_receive {:token_request, _type, _body}, 200
    end

    test "an unknown expiry is assumed valid rather than refreshed on every call", %{token_url: url} do
      model = expiring_model(url, 0)
      model = %{model | oauth: Map.put(model.oauth, "expires_at", nil)}
      Config.put_model(model)

      assert OAuth.ensure_fresh(Config.get_model("sub")).api_key == "old-access"
      refute_receive {:token_request, _type, _body}, 200
    end

    test "a failed refresh leaves the connection as it was", %{token_url: url} do
      answers(:fail)
      Config.put_model(expiring_model(url, 10))

      # The dead token is handed back, so the request fails and is reported gracefully -
      # far better than crashing here, where nobody is listening.
      assert OAuth.ensure_fresh(Config.get_model("sub")).api_key == "old-access"
      assert Config.get_model("sub").api_key == "old-access"
    end

    test "a refresh grant that returns no new refresh token keeps the old one", %{token_url: url} do
      # Some providers rotate the refresh token, some don't. Dropping it when they don't
      # would silently make the connection unrefreshable from the next expiry on.
      answers(%{"access_token" => "fresh-access", "expires_in" => 3600})
      Config.put_model(expiring_model(url, 10))

      fresh = OAuth.ensure_fresh(Config.get_model("sub"))

      assert fresh.api_key == "fresh-access"
      assert fresh.oauth["refresh"] == "old-refresh"
    end

    test "a plain API-key connection is never touched by ensure_fresh" do
      model = %Model{name: "plain", base_url: "https://x", api_key: "sk-1", model: "gpt"}

      assert OAuth.ensure_fresh(model) == model
      refute_receive {:token_request, _type, _body}, 200
    end

    test "apply_tokens merges a fresh sign-in onto an existing connection and persists it", %{token_url: url} do
      Config.put_model(expiring_model(url, 10))
      tokens = %{access: "re-access", refresh: "re-refresh", expires_at: 1_234}

      updated = OAuth.apply_tokens(Config.get_model("sub"), tokens)

      assert updated.api_key == "re-access"
      assert updated.oauth["expires_at"] == 1_234
      # Everything else about the connection survives the reconnect - that is the whole
      # point of merging instead of rebuilding: agents pointing at it keep working.
      assert updated.base_url == "https://api.example.com"
      assert updated.oauth["provider"] == "openai"
      assert Config.get_model("sub").oauth["refresh"] == "re-refresh"
    end
  end

  describe "a callback the user never completes" do
    setup do
      {:ok, _} = Application.ensure_all_started(:bandit)
      {:ok, _} = Application.ensure_all_started(:req)
      :ok
    end

    defp callback_server(state) do
      ref = make_ref()

      {:ok, server} =
        Bandit.start_link(
          plug: {Pepe.OAuth.Callback, owner: self(), ref: ref, state: state, path: "/auth/callback"},
          scheme: :http,
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> Process.exit(server, :normal) end)
      {ref, port}
    end

    test "the provider's own denial is surfaced, not swallowed as a missing code" do
      {ref, port} = callback_server("st")

      Req.get!("http://127.0.0.1:#{port}/auth/callback?error=access_denied&state=st")

      assert_receive {:oauth_error, ^ref, "access_denied"}, 2_000
    end

    test "a redirect that carries no code at all is an error, not an empty login" do
      {ref, port} = callback_server("st")

      Req.get!("http://127.0.0.1:#{port}/auth/callback?state=st")

      assert_receive {:oauth_error, ^ref, :missing_code}, 2_000
    end

    test "a request to any other path is not mistaken for the redirect" do
      {_ref, port} = callback_server("st")

      assert Req.get!("http://127.0.0.1:#{port}/favicon.ico").status == 404
    end
  end

  test "begin/2 hands back a session with no callback server when the port can't be bound" do
    # Two sign-ins racing for the same loopback port (or an SSH session where nothing can
    # bind at all): the second must degrade to the paste-the-code route, not blow up.
    flow = %{
      authorize_url: "https://auth.example.com/authorize",
      token_url: "https://auth.example.com/token",
      client_id: "c-1",
      redirect_uri: "http://localhost:14561/cb",
      scope: "openid",
      callback_port: 14_561,
      callback_path: "/cb"
    }

    assert {:ok, first} = OAuth.begin(flow)
    assert is_pid(first.pid)

    assert {:ok, second} = OAuth.begin(flow)
    assert second.pid == nil

    # Cancelling a session that never got a server is a no-op, not a crash.
    assert OAuth.cancel(second) == :ok
    assert OAuth.cancel(first)
  end
end
