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

  A thin provider config over `Pepe.Webhooks.JwtVerifier`'s shared parse/verify-signature/
  check-claims/cache-the-keys engine - the only Chat-specific piece is the single JWK
  endpoint the keys come from (see `fetch_keys/0`). A configured project number typed as an
  integer is coerced to a string by the caller (`Pepe.Webhooks.GoogleChat`), before it ever
  reaches `verify/2` here - `audience_match?/2` is a plain string equality.
  """

  alias Pepe.Webhooks.JwtVerifier

  # Google publishes this service account's signing keys as a JWK set - the same n/e shape
  # Pepe.Webhooks.MsTeamsJwt already consumes, so no X.509/PEM decoding is needed. (Google's docs
  # page names the sibling x509-cert endpoint; this JWK one returns the same keys pre-parsed, and
  # is the shape Google's own client libraries use for other system accounts.)
  @jwk_url "https://www.googleapis.com/service_accounts/v1/jwk/chat@system.gserviceaccount.com"
  @issuer "chat@system.gserviceaccount.com"

  @doc """
  Verify an inbound Google Chat token for the app registered under `project_number`. Returns
  `:ok` when the token is authentic and addressed to this project, `{:error, reason}` otherwise.
  """
  @spec verify(String.t(), String.t()) :: :ok | {:error, term()}
  def verify(token, project_number)
      when is_binary(token) and is_binary(project_number) and project_number != "" do
    JwtVerifier.verify(token, project_number, config())
  end

  def verify(_token, _project_number), do: {:error, :missing_token_or_audience}

  @doc false
  def reset_cache, do: JwtVerifier.reset_cache(:googlechat)

  defp config do
    %{name: :googlechat, issuer: @issuer, fetch_keys: &fetch_keys/0, audience_match: &audience_match?/2}
  end

  defp fetch_keys do
    case Req.get(@jwk_url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) -> {:ok, keys}
      other -> {:error, other}
    end
  end

  # project_number arrives already coerced to a string by verify/2's own is_binary guard (and,
  # a level up, by googlechat.ex's own to_string/1 on a possibly-integer config value) - a
  # plain equality is enough, nothing here ever sees a non-string on either side.
  defp audience_match?(aud, project_number) when is_binary(aud), do: aud == project_number
  defp audience_match?(_aud, _project_number), do: false
end
