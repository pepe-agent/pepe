defmodule Pepe.Webhooks.GoogleChatJwt do
  @moduledoc """
  Validates the inbound Google-signed JWT so the Google Chat webhook can accept `POST`s
  directly from Google, no validating reverse-proxy required - the same native-verification
  parity `Pepe.Webhooks.MsTeamsJwt` gives Microsoft Teams.

  Scope: this covers the **Project Number** authentication-audience flavor (the Chat app's
  "Authentication Audience" setting in the Google Cloud Console). In that flavor Google mints a
  self-signed JWT: `iss` is the Chat system service account, `aud` is the Cloud project number
  the Chat app is registered under, signed with that service account's own published keys - so a
  valid signature already proves the request came from Google Chat, no further identity claim
  needed. (Google also offers an "HTTP endpoint URL" audience flavor, a general Google ID token
  whose identity instead rides in an `email` claim pinned to the same service account - a
  different verification shape, not covered here. An app configured for that flavor gets every
  message rejected as a bad audience; the dashboard config hint says to pick Project Number.)

  `verify/2` proves the token:

    * signature checks out against Google's published RSA keys (JWK, cached), and
    * `iss` is the Chat system service account, and
    * `aud` equals the operator's configured project number, and
    * the token is inside its `exp` window (with a small clock-skew tolerance).

  No JWT dependency is pulled in - RS256 is verified with `:crypto` directly, same as
  `Pepe.Webhooks.MsTeamsJwt` and the Discord provider's Ed25519 signatures.
  """

  require Logger

  # Google publishes this service account's signing keys as a JWK set - the same n/e shape
  # Pepe.Webhooks.MsTeamsJwt already consumes, so no X.509/PEM decoding is needed. (Google's docs
  # page names the sibling x509-cert endpoint; this JWK one returns the same keys pre-parsed, and
  # is the shape Google's own client libraries use for other system accounts.)
  @jwk_url "https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com"
  @issuer "chat@system.gserviceaccount.com"

  # Allow a little clock drift between Google and this host.
  @skew_seconds 300

  # Google rotates these keys roughly every two weeks; re-fetch at most once a day in the
  # ordinary case, but a token whose `kid` isn't cached forces an out-of-band refresh regardless,
  # so a rotation is picked up immediately rather than waiting out the TTL.
  @cache_ttl_ms 24 * 60 * 60 * 1000
  @cache_key {__MODULE__, :jwks}

  @doc """
  Verify an inbound Google Chat token for the app registered under `project_number`. Returns
  `:ok` when the token is authentic and addressed to this project, `{:error, reason}` otherwise.
  """
  @spec verify(String.t(), String.t()) :: :ok | {:error, term()}
  def verify(token, project_number)
      when is_binary(token) and is_binary(project_number) and project_number != "" do
    with {:ok, header, payload, signing_input, sig} <- parse(token),
         {:ok, kid} <- signing_kid(header),
         {:ok, jwk} <- signing_key(kid),
         :ok <- check_signature(signing_input, sig, jwk) do
      check_claims(payload, project_number)
    end
  end

  def verify(_token, _project_number), do: {:error, :missing_token_or_audience}

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

  defp check_signature(signing_input, sig, %{"kty" => "RSA", "n" => n64, "e" => e64}) do
    with {:ok, n} <- Base.url_decode64(n64, padding: false),
         {:ok, e} <- Base.url_decode64(e64, padding: false),
         true <- :crypto.verify(:rsa, :sha256, signing_input, sig, [e, n]) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  end

  defp check_signature(_signing_input, _sig, _jwk), do: {:error, :unsupported_key}

  # --- claims ----------------------------------------------------------------

  defp check_claims(payload, project_number) do
    now = System.system_time(:second)

    cond do
      payload["iss"] != @issuer -> {:error, :bad_issuer}
      not audience_match?(payload["aud"], project_number) -> {:error, :bad_audience}
      expired?(payload["exp"], now) -> {:error, :expired}
      not_yet_valid?(payload["nbf"], now) -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  # A pasted project number in config may already be a string; the claim itself is always a
  # string too, but compare loosely on either side so an operator-entered integer still matches.
  defp audience_match?(aud, project_number) when is_binary(aud), do: aud == to_string(project_number)
  defp audience_match?(_aud, _project_number), do: false

  defp expired?(exp, now) when is_integer(exp), do: now > exp + @skew_seconds
  defp expired?(_exp, _now), do: true

  defp not_yet_valid?(nbf, now) when is_integer(nbf), do: now + @skew_seconds < nbf
  defp not_yet_valid?(_nbf, _now), do: false

  # --- JWK cache ---------------------------------------------------------------

  defp signing_key(kid) do
    case cached_key(kid) do
      {:ok, jwk} -> {:ok, jwk}
      :miss -> refresh_and_fetch(kid)
    end
  end

  defp refresh_and_fetch(kid) do
    with {:ok, keys} <- refresh(), do: fetch_key(keys, kid)
  end

  defp fetch_key(keys, kid) do
    case Map.fetch(keys, kid) do
      {:ok, jwk} -> {:ok, jwk}
      :error -> {:error, :unknown_kid}
    end
  end

  defp cached_key(kid) do
    case :persistent_term.get(@cache_key, nil) do
      %{at: at, keys: keys} ->
        if fresh?(at) and Map.has_key?(keys, kid), do: {:ok, keys[kid]}, else: :miss

      _ ->
        :miss
    end
  end

  defp fresh?(at), do: System.monotonic_time(:millisecond) - at < @cache_ttl_ms

  defp refresh do
    case Req.get(@jwk_url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        by_kid = for %{"kid" => kid} = key <- keys, into: %{}, do: {kid, key}
        :persistent_term.put(@cache_key, %{at: System.monotonic_time(:millisecond), keys: by_kid})
        {:ok, by_kid}

      other ->
        Logger.error("[googlechat] could not fetch Chat signing keys: #{inspect(other)}")
        {:error, :jwks_fetch_failed}
    end
  end

  @doc false
  # Test hook: drop the cached signing keys so a fresh fetch is forced.
  def reset_cache, do: :persistent_term.erase(@cache_key)
end
