defmodule Pepe.OAuthTest do
  use ExUnit.Case, async: false

  alias Pepe.Config
  alias Pepe.Config.Model
  alias Pepe.OAuth

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
end
