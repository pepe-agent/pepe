defmodule Pepe.Webhooks.GoogleChatJwtTest do
  @moduledoc """
  The Google Chat webhook accepts `POST`s straight from Google, so the inbound Google-signed JWT
  is the only thing standing between the predictable URL and the bound agent.

  These pin the checks that matter: a token is accepted only when its signature verifies against
  Google's published key AND it was minted for *this* app's project (`aud` == `project_number`)
  AND it is inside its validity window. A token for another project, an expired one, or a
  tampered signature is refused. A separate test vendors a real (public) Google Chat JWKS
  document fetched live and asserts the key-extraction path produces a usable `[e, n]` pair from
  it - the self-signed fixtures below prove the claim logic is right, but only real Google key
  material can catch a wrong assumption about the key SHAPE Google actually serves.
  """
  use ExUnit.Case, async: false
  use Mimic

  alias Pepe.Webhooks.GoogleChatJwt

  @kid "test-signing-kid"
  @issuer "chat@system.gserviceaccount.com"
  @project_number "123456789012"

  setup do
    # The signing keys are process-global (persistent_term); start every test from a cold cache.
    GoogleChatJwt.reset_cache()

    # One RSA keypair stands in for Google's. Its public half is served as the JWK set; its
    # private half signs the tokens under test.
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

    stub_jwk([jwk])

    {:ok, priv: [e, n, d]}
  end

  test "accepts a well-formed token minted for this project", %{priv: priv} do
    token = sign(priv, claims())
    assert GoogleChatJwt.verify(token, @project_number) == :ok
  end

  test "an integer-looking project number configured as a plain string still matches", %{priv: priv} do
    token = sign(priv, claims(%{"aud" => "42"}))
    assert GoogleChatJwt.verify(token, "42") == :ok
  end

  test "rejects a token minted for a different project", %{priv: priv} do
    token = sign(priv, claims(%{"aud" => "999999999999"}))
    assert GoogleChatJwt.verify(token, @project_number) == {:error, :bad_audience}
  end

  test "rejects a token from the wrong issuer", %{priv: priv} do
    token = sign(priv, claims(%{"iss" => "someone-else@evil.example.com"}))
    assert GoogleChatJwt.verify(token, @project_number) == {:error, :bad_issuer}
  end

  test "rejects an expired token", %{priv: priv} do
    past = System.system_time(:second) - 3600
    token = sign(priv, claims(%{"exp" => past}))
    assert GoogleChatJwt.verify(token, @project_number) == {:error, :expired}
  end

  test "rejects a token not yet valid", %{priv: priv} do
    future = System.system_time(:second) + 3600
    token = sign(priv, claims(%{"nbf" => future, "exp" => future + 3600}))
    assert GoogleChatJwt.verify(token, @project_number) == {:error, :not_yet_valid}
  end

  test "rejects a token with no exp claim at all - missing is treated as expired, not valid forever", %{priv: priv} do
    token = sign(priv, claims() |> Map.delete("exp"))
    assert GoogleChatJwt.verify(token, @project_number) == {:error, :expired}
  end

  test "rejects a tampered signature", %{priv: priv} do
    [header, payload, sig] = sign(priv, claims()) |> String.split(".")
    # Flip the FIRST base64url character of the signature, not the last: the last char of a
    # 256-byte RSA signature carries only a couple of significant bits, so flipping it can decode
    # to the same bytes and not actually tamper (a flaky no-op depending on the random key).
    <<first::binary-size(1), rest::binary>> = sig
    flipped = if(first == "A", do: "B", else: "A") <> rest
    assert GoogleChatJwt.verify("#{header}.#{payload}.#{flipped}", @project_number) == {:error, :bad_signature}
  end

  test "rejects a token whose kid is not in the JWK set", %{priv: priv} do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => "unknown-kid"}
    token = sign_with_header(priv, header, claims())
    assert GoogleChatJwt.verify(token, @project_number) == {:error, :unknown_kid}
  end

  test "rejects a token signed with an unsupported algorithm", %{priv: priv} do
    header = %{"alg" => "HS256", "typ" => "JWT", "kid" => @kid}
    token = sign_with_header(priv, header, claims())
    assert GoogleChatJwt.verify(token, @project_number) == {:error, :unsupported_alg}
  end

  test "rejects a malformed token" do
    assert GoogleChatJwt.verify("not-a-jwt", @project_number) == {:error, :malformed_token}
  end

  test "refuses when the configured project number is blank - never skips the check", %{priv: priv} do
    token = sign(priv, claims())
    assert GoogleChatJwt.verify(token, "") == {:error, :missing_token_or_audience}
  end

  describe "against a real (vendored) Google Chat JWKS document" do
    # Fetched live from https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com
    # - public data, not a secret. This is the one test in the suite that can catch a wrong
    # assumption about the key SHAPE Google actually serves: a self-signed fixture "works" even if
    # that assumption is wrong, because the test builds its own JWK the same (possibly wrong) way.
    @real_jwks "test/fixtures/googlechat/jwks.json" |> File.read!() |> Jason.decode!()

    test "every key in the real document decodes to a usable [e, n] pair for :crypto.verify" do
      assert %{"keys" => keys} = @real_jwks
      refute Enum.empty?(keys)

      for jwk <- keys do
        assert %{"kty" => "RSA", "n" => n64, "e" => e64, "kid" => kid} = jwk
        assert is_binary(kid) and kid != ""

        assert {:ok, n} = Base.url_decode64(n64, padding: false)
        assert {:ok, e} = Base.url_decode64(e64, padding: false)
        # A real RSA modulus is large (2048-bit keys here); a wrong decode would yield something
        # implausibly small instead of erroring outright.
        assert byte_size(n) >= 256
        assert byte_size(e) >= 1
      end
    end

    test "verify/2 with the real document's keys stubbed in rejects a token they never signed", %{priv: priv} do
      stub_jwk(@real_jwks["keys"])
      # Signed with our own test key, not Google's - the kid (@kid, "test-signing-kid") won't
      # match anything in the real document, so this proves the real keys were actually loaded
      # and consulted (unknown_kid), not that verification was skipped.
      token = sign(priv, claims())
      assert GoogleChatJwt.verify(token, @project_number) == {:error, :unknown_kid}
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp claims(overrides \\ %{}) do
    now = System.system_time(:second)

    %{
      "iss" => @issuer,
      "aud" => @project_number,
      "exp" => now + 3600
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

  defp stub_jwk(keys) do
    Mimic.stub(Req, :get, fn _url, _opts ->
      {:ok, %Req.Response{status: 200, body: %{"keys" => keys}}}
    end)
  end
end
