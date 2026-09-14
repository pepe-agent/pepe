defmodule Pepe.Webhooks.JwtVerifierTest do
  @moduledoc """
  `Pepe.Webhooks.JwtVerifier`'s own contract, independent of its two callers
  (`MsTeamsJwt`/`GoogleChatJwt`, each already exercised end to end in their own test
  files). Focused on what parameterizing the shared engine by `config.name` newly has to
  get right: two different providers never collide in the signing-key cache.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pepe.Webhooks.JwtVerifier

  @issuer "https://issuer.example.com"

  setup do
    JwtVerifier.reset_cache(:provider_a)
    JwtVerifier.reset_cache(:provider_b)
    :ok
  end

  defp keypair do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    {elem(key, 2), elem(key, 3), elem(key, 4)}
  end

  defp jwk(kid, n, e) do
    %{"kty" => "RSA", "kid" => kid, "n" => b64(:binary.encode_unsigned(n)), "e" => b64(:binary.encode_unsigned(e))}
  end

  defp sign(e, n, d, kid, claims) do
    header = %{"alg" => "RS256", "typ" => "JWT", "kid" => kid}
    signing_input = "#{b64(Jason.encode!(header))}.#{b64(Jason.encode!(claims))}"
    sig = :crypto.sign(:rsa, :sha256, signing_input, [e, n, d])
    "#{signing_input}.#{b64(sig)}"
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp claims(aud) do
    now = System.system_time(:second)
    %{"iss" => @issuer, "aud" => aud, "exp" => now + 3600, "nbf" => now - 60}
  end

  defp config(name, fetch_keys) do
    %{name: name, issuer: @issuer, fetch_keys: fetch_keys, audience_match: &(&1 == &2)}
  end

  test "verifies a well-formed token against a directly-built config" do
    {n, e, d} = keypair()
    token = sign(e, n, d, "k1", claims("aud-1"))
    fetch = fn -> {:ok, [jwk("k1", n, e)]} end

    assert JwtVerifier.verify(token, "aud-1", config(:provider_a, fetch)) == :ok
  end

  test "verify/3 refuses a blank audience without calling fetch_keys at all" do
    fetch = fn -> flunk("fetch_keys should not be called for a refused blank audience") end
    assert JwtVerifier.verify("token", "", config(:provider_a, fetch)) == {:error, :missing_token_or_audience}
  end

  test "an empty token fails as malformed, same as any other unparseable token" do
    fetch = fn -> flunk("fetch_keys should not be called before a token even parses") end
    assert JwtVerifier.verify("", "aud-1", config(:provider_a, fetch)) == {:error, :malformed_token}
  end

  test "two providers cache signing keys independently - one's keys never answer for the other" do
    {n_a, e_a, d_a} = keypair()
    {n_b, e_b, d_b} = keypair()

    token_a = sign(e_a, n_a, d_a, "shared-kid", claims("aud-a"))
    token_b = sign(e_b, n_b, d_b, "shared-kid", claims("aud-b"))

    fetch_a = fn -> {:ok, [jwk("shared-kid", n_a, e_a)]} end
    fetch_b = fn -> {:ok, [jwk("shared-kid", n_b, e_b)]} end

    # Same kid, different keys, different provider names - populate both caches.
    assert JwtVerifier.verify(token_a, "aud-a", config(:provider_a, fetch_a)) == :ok
    assert JwtVerifier.verify(token_b, "aud-b", config(:provider_b, fetch_b)) == :ok

    # provider_a's cached key must not verify provider_b's token, even though the kid matches -
    # if the cache were shared by kid alone (not name), this signature check would still fail
    # correctly, so also prove provider_a's cache genuinely holds ITS OWN key by re-verifying its
    # own token with fetch_keys short-circuited to something that would blow up if ever called.
    boom = fn -> flunk("should have hit the cache, not refetched") end
    assert JwtVerifier.verify(token_a, "aud-a", config(:provider_a, boom)) == :ok
    assert JwtVerifier.verify(token_b, "aud-b", config(:provider_b, boom)) == :ok
  end

  test "reset_cache/1 only clears the named provider's cache" do
    {n, e, d} = keypair()
    token = sign(e, n, d, "k1", claims("aud-1"))
    fetch = fn -> {:ok, [jwk("k1", n, e)]} end

    assert JwtVerifier.verify(token, "aud-1", config(:provider_a, fetch)) == :ok
    assert JwtVerifier.verify(token, "aud-1", config(:provider_b, fetch)) == :ok

    JwtVerifier.reset_cache(:provider_a)

    # provider_b's own cache must be untouched by resetting provider_a - check this FIRST,
    # by making its fetch explode if ever called, before anything re-populates any cache.
    boom = fn -> flunk("provider_b's cache should not have been reset") end
    assert JwtVerifier.verify(token, "aud-1", config(:provider_b, boom)) == :ok

    # provider_a was reset, so it must genuinely refetch, proven by asserting fetch/0 itself runs.
    tracking_fetch = fn ->
      send(self(), :refetched)
      fetch.()
    end

    assert JwtVerifier.verify(token, "aud-1", config(:provider_a, tracking_fetch)) == :ok
    assert_received :refetched
  end

  test "a fetch_keys failure surfaces as :jwks_fetch_failed, not a crash" do
    fetch = fn -> {:error, :timeout} end
    {n, e, d} = keypair()
    token = sign(e, n, d, "k1", claims("aud-1"))

    capture_log(fn ->
      assert JwtVerifier.verify(token, "aud-1", config(:provider_a, fetch)) == {:error, :jwks_fetch_failed}
    end)
  end

  test "an unknown kid throttles repeated fetch_keys calls, instead of refetching every time" do
    {n, e, d} = keypair()
    calls = :counters.new(1, [])

    fetch = fn ->
      :counters.add(calls, 1, 1)
      {:ok, [jwk("k1", n, e)]}
    end

    # Every one of these carries a DIFFERENT unknown kid - a real attacker's flood, not the
    # same cache-missing lookup repeated. Only the throttle (not the per-kid cache) can
    # possibly bound the fetch_keys call count here.
    for i <- 1..5 do
      token = sign(e, n, d, "unknown-#{i}", claims("aud-1"))
      assert JwtVerifier.verify(token, "aud-1", config(:provider_a, fetch)) == {:error, :unknown_kid}
    end

    assert :counters.get(calls, 1) == 1
  end

  test "a fetch_keys failure is also throttled, not retried on every subsequent request" do
    calls = :counters.new(1, [])

    fetch = fn ->
      :counters.add(calls, 1, 1)
      {:error, :timeout}
    end

    {n, e, d} = keypair()
    token = sign(e, n, d, "k1", claims("aud-1"))

    capture_log(fn ->
      # The throttle applies regardless of outcome, so a call throttled by an earlier
      # failed attempt reads the same as an unknown kid (:unknown_kid), not a repeat of
      # the original :jwks_fetch_failed - fetch_keys itself genuinely only runs once.
      assert JwtVerifier.verify(token, "aud-1", config(:provider_a, fetch)) == {:error, :jwks_fetch_failed}

      for _ <- 1..2 do
        assert JwtVerifier.verify(token, "aud-1", config(:provider_a, fetch)) == {:error, :unknown_kid}
      end
    end)

    assert :counters.get(calls, 1) == 1
  end
end
