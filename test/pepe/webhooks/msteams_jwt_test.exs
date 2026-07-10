defmodule Pepe.Webhooks.MsTeamsJwtTest do
  @moduledoc """
  The Microsoft Teams webhook accepts `POST`s straight from Microsoft, so the inbound Bot
  Framework JWT is the only thing standing between the predictable URL and the bound agent.

  These pin the checks that matter: a token is accepted only when its signature verifies against
  Microsoft's published key AND it was minted for *this* bot (`aud` == `app_id`) AND it is inside
  its validity window. A token for another bot, an expired one, or a tampered signature is refused.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Webhooks.MsTeamsJwt

  @kid "test-signing-kid"
  @issuer "https://api.botframework.com"
  @app_id "11111111-1111-1111-1111-111111111111"

  setup do
    # The signing keys are process-global (persistent_term); start every test from a cold cache.
    MsTeamsJwt.reset_cache()

    # One RSA keypair stands in for the Bot Framework's. Its public half is served as the JWKS;
    # its private half signs the tokens under test.
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    n = elem(key, 2)
    e = elem(key, 3)
    d = elem(key, 4)

    jwk = %{
      "kty" => "RSA",
      "kid" => @kid,
      "use" => "sig",
      "alg" => "RS256",
      "n" => b64(:binary.encode_unsigned(n)),
      "e" => b64(:binary.encode_unsigned(e))
    }

    stub_jwks([jwk])

    {:ok, priv: [e, n, d]}
  end

  test "accepts a well-formed token minted for this bot", %{priv: priv} do
    token = sign(priv, claims())
    assert MsTeamsJwt.verify(token, @app_id) == :ok
  end

  test "rejects a token minted for a different bot", %{priv: priv} do
    token = sign(priv, claims(%{"aud" => "22222222-2222-2222-2222-222222222222"}))
    assert MsTeamsJwt.verify(token, @app_id) == {:error, :bad_audience}
  end

  test "rejects a token from the wrong issuer", %{priv: priv} do
    token = sign(priv, claims(%{"iss" => "https://evil.example.com"}))
    assert MsTeamsJwt.verify(token, @app_id) == {:error, :bad_issuer}
  end

  test "rejects an expired token", %{priv: priv} do
    past = System.system_time(:second) - 3600
    token = sign(priv, claims(%{"exp" => past, "nbf" => past - 60}))
    assert MsTeamsJwt.verify(token, @app_id) == {:error, :expired}
  end

  test "rejects a token not yet valid", %{priv: priv} do
    future = System.system_time(:second) + 3600
    token = sign(priv, claims(%{"nbf" => future, "exp" => future + 3600}))
    assert MsTeamsJwt.verify(token, @app_id) == {:error, :not_yet_valid}
  end

  test "rejects a tampered signature", %{priv: priv} do
    [header, payload, sig] = sign(priv, claims()) |> String.split(".")
    # Flip the FIRST base64url character of the signature. Not the last: the last char of a 256-byte
    # RSA signature carries only a couple of significant bits, and Base.url_decode64 discards the
    # rest, so flipping it can decode to the same bytes and not actually tamper (a flaky no-op that
    # depended on the random key). The first char always encodes significant bits.
    <<first::binary-size(1), rest::binary>> = sig
    flipped = if(first == "A", do: "B", else: "A") <> rest
    assert MsTeamsJwt.verify("#{header}.#{payload}.#{flipped}", @app_id) == {:error, :bad_signature}
  end

  test "rejects a token whose kid is not in the JWKS", %{priv: priv} do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => "unknown-kid"}
    token = sign_with_header(priv, header, claims())
    assert MsTeamsJwt.verify(token, @app_id) == {:error, :unknown_kid}
  end

  test "rejects a token signed with an unsupported algorithm", %{priv: priv} do
    header = %{"alg" => "HS256", "typ" => "JWT", "kid" => @kid}
    token = sign_with_header(priv, header, claims())
    assert MsTeamsJwt.verify(token, @app_id) == {:error, :unsupported_alg}
  end

  test "rejects a malformed token" do
    assert MsTeamsJwt.verify("not-a-jwt", @app_id) == {:error, :malformed_token}
  end

  test "refuses when the app id is blank", %{priv: priv} do
    token = sign(priv, claims())
    assert MsTeamsJwt.verify(token, "") == {:error, :missing_token_or_app_id}
  end

  # --- helpers ---------------------------------------------------------------

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    %{
      "iss" => @issuer,
      "aud" => @app_id,
      "nbf" => now - 60,
      "exp" => now + 3600,
      "serviceurl" => "https://smba.trafficmanager.net/teams/"
    }
    |> Map.merge(overrides)
  end

  defp sign(priv, claims), do: sign_with_header(priv, %{"alg" => "RS256", "typ" => "JWT", "kid" => @kid}, claims)

  defp sign_with_header([e, n, d], header, claims) do
    signing_input = "#{b64(Jason.encode!(header))}.#{b64(Jason.encode!(claims))}"
    sig = :crypto.sign(:rsa, :sha256, signing_input, [e, n, d])
    "#{signing_input}.#{b64(sig)}"
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp stub_jwks(keys) do
    Mimic.stub(Req, :get, fn url, _opts ->
      cond do
        String.contains?(url, "openidconfiguration") ->
          {:ok, %Req.Response{status: 200, body: %{"jwks_uri" => "https://login.botframework.com/v1/keys"}}}

        String.contains?(url, "/keys") ->
          {:ok, %Req.Response{status: 200, body: %{"keys" => keys}}}

        true ->
          {:ok, %Req.Response{status: 404, body: ""}}
      end
    end)
  end
end
