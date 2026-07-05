defmodule Pepe.Webhooks.MsTeamsJwt do
  @moduledoc """
  Validates the inbound Bot Framework JWT so the Microsoft Teams webhook can accept
  `POST`s directly from Microsoft, no validating reverse-proxy required.

  Every activity the connector delivers carries an `Authorization: Bearer <jwt>` signed
  by the Bot Framework. `verify/2` proves the request genuinely came from Microsoft and
  is addressed to *this* bot:

    * the signature checks out against the Bot Framework's published RSA keys (JWKS),
    * `iss` is the Bot Framework connector,
    * `aud` is the bot's own app id (so a token minted for another bot is rejected), and
    * the token is inside its `nbf`/`exp` window (with a small clock-skew tolerance).

  The signing keys are fetched from the connector's OpenID metadata and cached; a key
  rotation (an unknown `kid`) forces a refresh. No JWT dependency is pulled in - RS256 is
  verified with `:crypto` directly, the same dependency-free approach the Discord provider
  uses for its Ed25519 signatures.
  """

  require Logger

  # The Bot Framework's public OpenID metadata; its `jwks_uri` points at the signing keys.
  @openid_config_url "https://login.botframework.com/v1/.well-known/openidconfiguration"
  @issuer "https://api.botframework.com"

  # Allow a little clock drift between Microsoft and this host.
  @skew_seconds 300

  # Re-fetch the signing keys at most once a day; a token whose `kid` is not cached forces
  # an out-of-band refresh regardless, so a rotation is picked up immediately.
  @cache_ttl_ms 24 * 60 * 60 * 1000
  @cache_key {__MODULE__, :jwks}

  @doc """
  Verify an inbound Bot Framework token for the bot identified by `app_id`.
  Returns `:ok` when the token is authentic and addressed to this bot, `{:error, reason}`
  otherwise.
  """
  @spec verify(String.t(), String.t()) :: :ok | {:error, term()}
  def verify(token, app_id) when is_binary(token) and is_binary(app_id) and app_id != "" do
    with {:ok, header, payload, signing_input, sig} <- parse(token),
         {:ok, kid} <- signing_kid(header),
         {:ok, jwk} <- signing_key(kid),
         :ok <- check_signature(signing_input, sig, jwk) do
      check_claims(payload, app_id)
    end
  end

  def verify(_token, _app_id), do: {:error, :missing_token_or_app_id}

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

  defp check_claims(payload, app_id) do
    now = System.system_time(:second)

    cond do
      payload["iss"] != @issuer -> {:error, :bad_issuer}
      not audience_match?(payload["aud"], app_id) -> {:error, :bad_audience}
      expired?(payload["exp"], now) -> {:error, :expired}
      not_yet_valid?(payload["nbf"], now) -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp audience_match?(aud, app_id) when is_binary(aud), do: aud == app_id
  defp audience_match?(aud, app_id) when is_list(aud), do: app_id in aud
  defp audience_match?(_aud, _app_id), do: false

  defp expired?(exp, now) when is_integer(exp), do: now > exp + @skew_seconds
  defp expired?(_exp, _now), do: true

  defp not_yet_valid?(nbf, now) when is_integer(nbf), do: now + @skew_seconds < nbf
  defp not_yet_valid?(_nbf, _now), do: false

  # --- JWKS cache ------------------------------------------------------------

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
    with {:ok, %{status: 200, body: %{"jwks_uri" => uri}}} when is_binary(uri) <-
           Req.get(@openid_config_url, receive_timeout: 10_000),
         {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) <-
           Req.get(uri, receive_timeout: 10_000) do
      by_kid = for %{"kid" => kid} = key <- keys, into: %{}, do: {kid, key}
      :persistent_term.put(@cache_key, %{at: System.monotonic_time(:millisecond), keys: by_kid})
      {:ok, by_kid}
    else
      other ->
        Logger.error("[msteams] could not fetch Bot Framework signing keys: #{inspect(other)}")
        {:error, :jwks_fetch_failed}
    end
  end

  @doc false
  # Test hook: drop the cached signing keys so a fresh fetch is forced.
  def reset_cache, do: :persistent_term.erase(@cache_key)
end
