defmodule Pepe.Webhooks.JwtVerifier do
  @moduledoc """
  Shared RS256-over-JWKS verification engine used by every inbound-webhook provider that
  proves a request's origin by validating a signed JWT instead of trusting a validating
  reverse-proxy (`Pepe.Webhooks.MsTeamsJwt`, `Pepe.Webhooks.GoogleChatJwt`). Extracted
  because those two started as near-identical ~150-line copies of the same parse/
  verify-signature/check-claims/cache-the-signing-keys engine, differing only in where the
  keys come from, what `iss` to expect, and how to compare `aud` - each provider is now a
  thin `config/0` plus its own two provider-specific functions, both wrapping this module's
  single `verify/3`.

  No JWT dependency is pulled in - RS256 is verified with `:crypto` directly, the same
  dependency-free approach the Discord provider uses for its Ed25519 signatures.

  A `config` map has four keys:

    * `:name` - an atom identifying the provider (`:msteams`, `:googlechat`, ...) - keys
      the signing-key cache so two providers never collide, and tags the fetch-failure log.
    * `:issuer` - the exact `iss` claim value to require.
    * `:fetch_keys` - a 0-arity function returning `{:ok, [jwk, ...]}` (the raw JWKS
      `"keys"` list) or `{:error, reason}` - however that provider's keys are actually
      published (a two-step OpenID-metadata lookup for Microsoft, one direct JWK endpoint
      for Google).
    * `:audience_match` - a 2-arity function `(token_aud, expected_audience) -> boolean()`
      - however that provider's `aud` claim should be compared (Microsoft allows a list
      `aud`; Google's is always a bare string compared loosely against an operator-typed
      value that might be an integer).
  """

  require Logger

  @skew_seconds 300
  # Re-fetch a provider's signing keys at most once a day; a token whose `kid` isn't
  # cached forces an out-of-band refresh regardless, so a rotation is picked up
  # immediately rather than waiting out the TTL.
  @cache_ttl_ms 24 * 60 * 60 * 1000
  # These webhook endpoints are public and unauthenticated by design (the JWT itself IS the
  # authentication) - a `kid` never has to be valid to reach signing_key/2, so an unknown one
  # can't be trusted to mean "a real rotation happened". Without a floor between refresh
  # attempts, an attacker posting tokens with random `kid`s turns this into an amplifier
  # against the provider's own key endpoint (one to two outbound HTTPS calls each) and a
  # `:persistent_term.put/2` storm (a global heap scan per write) - both per garbage token.
  # A genuine rotation still gets picked up promptly: the first miss after this floor elapses
  # refetches the whole key set, not just the one `kid` being looked up.
  @refresh_throttle_ms 30_000

  @type config :: %{
          required(:name) => atom(),
          required(:issuer) => String.t(),
          required(:fetch_keys) => (-> {:ok, [map()]} | {:error, term()}),
          required(:audience_match) => (term(), String.t() -> boolean())
        }

  @doc """
  Verify `token` was signed by `config`'s provider, is inside its validity window, and is
  addressed to `audience`. Returns `:ok` or `{:error, reason}`.
  """
  @spec verify(String.t(), String.t(), config()) :: :ok | {:error, term()}
  def verify(token, audience, %{} = config) when is_binary(token) and is_binary(audience) and audience != "" do
    with {:ok, header, payload, signing_input, sig} <- parse(token),
         {:ok, kid} <- signing_kid(header),
         {:ok, jwk} <- signing_key(kid, config),
         :ok <- check_signature(signing_input, sig, jwk) do
      check_claims(payload, audience, config)
    end
  end

  def verify(_token, _audience, _config), do: {:error, :missing_token_or_audience}

  @doc "Drop a provider's cached signing keys (and refresh throttle) so the next `verify/3` forces a fresh fetch - a test hook."
  @spec reset_cache(atom()) :: :ok
  def reset_cache(name) do
    :persistent_term.erase(cache_key(name))
    :persistent_term.erase(throttle_key(name))
    :ok
  end

  # --- token parsing ---------------------------------------------------------

  defp parse(token) do
    with [h, p, s] <- String.split(token, "."),
         {:ok, header_bin} <- Base.url_decode64(h, padding: false),
         {:ok, header} <- Jason.decode(header_bin),
         {:ok, payload_bin} <- Base.url_decode64(p, padding: false),
         {:ok, payload} <- Jason.decode(payload_bin),
         {:ok, sig} <- Base.url_decode64(s, padding: false) do
      {:ok, header, payload, h <> "." <> p, sig}
    else
      _ -> {:error, :malformed_token}
    end
  end

  defp signing_kid(%{"alg" => "RS256", "kid" => kid}) when is_binary(kid), do: {:ok, kid}
  defp signing_kid(_header), do: {:error, :unsupported_alg}

  # --- signature -------------------------------------------------------------

  defp check_signature(signing_input, sig, %{"kty" => "RSA", "n" => n64, "e" => e64} = jwk) do
    if alg_compatible?(jwk) do
      with {:ok, n} <- Base.url_decode64(n64, padding: false),
           {:ok, e} <- Base.url_decode64(e64, padding: false),
           true <- :crypto.verify(:rsa, :sha256, signing_input, sig, [e, n]) do
        :ok
      else
        _ -> {:error, :bad_signature}
      end
    else
      {:error, :unsupported_key}
    end
  end

  defp check_signature(_signing_input, _sig, _jwk), do: {:error, :unsupported_key}

  # A JWK's own "alg" is optional (RFC 7517) - when present, it must agree with the "RS256"
  # signing_kid/1 already requires from the token's header, or a same-kty key published for
  # a different algorithm could verify a signature it was never meant to.
  defp alg_compatible?(%{"alg" => alg}), do: alg == "RS256"
  defp alg_compatible?(_jwk), do: true

  # --- claims ------------------------------------------------------------------

  defp check_claims(payload, audience, config) do
    now = System.system_time(:second)

    cond do
      payload["iss"] != config.issuer -> {:error, :bad_issuer}
      not config.audience_match.(payload["aud"], audience) -> {:error, :bad_audience}
      expired?(payload["exp"], now) -> {:error, :expired}
      not_yet_valid?(payload["nbf"], now) -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp expired?(exp, now) when is_integer(exp), do: now > exp + @skew_seconds
  defp expired?(_exp, _now), do: true

  defp not_yet_valid?(nbf, now) when is_integer(nbf), do: now + @skew_seconds < nbf
  defp not_yet_valid?(_nbf, _now), do: false

  # --- signing-key cache, one entry per provider name ---------------------------

  defp signing_key(kid, config) do
    case cached_key(kid, config.name) do
      {:ok, jwk} -> {:ok, jwk}
      :miss -> refresh_and_fetch(kid, config)
    end
  end

  defp refresh_and_fetch(kid, config) do
    if throttled?(config.name) do
      {:error, :unknown_kid}
    else
      mark_refresh_attempt(config.name)
      with {:ok, keys} <- refresh(config), do: fetch_key(keys, kid)
    end
  end

  defp throttled?(name) do
    case :persistent_term.get(throttle_key(name), nil) do
      nil -> false
      at -> System.monotonic_time(:millisecond) - at < @refresh_throttle_ms
    end
  end

  defp mark_refresh_attempt(name), do: :persistent_term.put(throttle_key(name), System.monotonic_time(:millisecond))

  defp fetch_key(keys, kid) do
    case Map.fetch(keys, kid) do
      {:ok, jwk} -> {:ok, jwk}
      :error -> {:error, :unknown_kid}
    end
  end

  defp cached_key(kid, name) do
    case :persistent_term.get(cache_key(name), nil) do
      %{at: at, keys: keys} ->
        if fresh?(at) and Map.has_key?(keys, kid), do: {:ok, keys[kid]}, else: :miss

      _ ->
        :miss
    end
  end

  defp fresh?(at), do: System.monotonic_time(:millisecond) - at < @cache_ttl_ms

  defp refresh(config) do
    case config.fetch_keys.() do
      {:ok, keys} when is_list(keys) ->
        by_kid = for %{"kid" => kid} = key <- keys, into: %{}, do: {kid, key}
        :persistent_term.put(cache_key(config.name), %{at: System.monotonic_time(:millisecond), keys: by_kid})
        {:ok, by_kid}

      other ->
        Logger.error("[#{config.name}] could not fetch signing keys: #{inspect(other, limit: 10, printable_limit: 512)}")
        {:error, :jwks_fetch_failed}
    end
  end

  defp cache_key(name), do: {__MODULE__, name}
  defp throttle_key(name), do: {__MODULE__, name, :throttle}
end
