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

  A thin provider config over `Pepe.Webhooks.JwtVerifier`'s shared parse/verify-signature/
  check-claims/cache-the-keys engine - the only Teams-specific pieces are where the
  signing keys come from (a two-step OpenID-metadata lookup, unlike Google Chat's single
  JWK endpoint - see `fetch_keys/0`) and that `aud` may be a list (a token can be minted
  for more than one bot at once).
  """

  alias Pepe.Webhooks.JwtVerifier

  # The Bot Framework's public OpenID metadata; its `jwks_uri` points at the signing keys.
  @openid_config_url "https://login.botframework.com/v1/.well-known/openidconfiguration"
  @issuer "https://api.botframework.com"

  @doc """
  Verify an inbound Bot Framework token for the bot identified by `app_id`.
  Returns `:ok` when the token is authentic and addressed to this bot, `{:error, reason}`
  otherwise.
  """
  @spec verify(String.t(), String.t()) :: :ok | {:error, term()}
  def verify(token, app_id) when is_binary(token) and is_binary(app_id) and app_id != "" do
    JwtVerifier.verify(token, app_id, config())
  end

  def verify(_token, _app_id), do: {:error, :missing_token_or_app_id}

  @doc false
  def reset_cache, do: JwtVerifier.reset_cache(:msteams)

  defp config do
    %{name: :msteams, issuer: @issuer, fetch_keys: &fetch_keys/0, audience_match: &audience_match?/2}
  end

  # A two-step fetch: the OpenID metadata document names the actual jwks_uri, which is
  # where the keys themselves live.
  defp fetch_keys do
    with {:ok, %{status: 200, body: %{"jwks_uri" => uri}}} when is_binary(uri) <-
           Req.get(@openid_config_url, receive_timeout: 10_000),
         {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) <-
           Req.get(uri, receive_timeout: 10_000) do
      {:ok, keys}
    else
      other -> {:error, other}
    end
  end

  defp audience_match?(aud, app_id) when is_binary(aud), do: aud == app_id
  defp audience_match?(aud, app_id) when is_list(aud), do: app_id in aud
  defp audience_match?(_aud, _app_id), do: false
end
