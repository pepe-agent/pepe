defmodule Cortex.OAuthTest do
  use ExUnit.Case, async: false

  alias Cortex.OAuth

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
      extra_params: %{"originator" => "cortex"}
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
    assert params["originator"] == "cortex"
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
          plug:
            {Cortex.OAuth.Callback,
             owner: self(), ref: ref, state: "st-ok", path: "/auth/callback"},
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
          plug:
            {Cortex.OAuth.Callback,
             owner: self(), ref: ref, state: "expected", path: "/auth/callback"},
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
end
