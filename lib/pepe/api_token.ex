defmodule Pepe.ApiToken do
  @moduledoc """
  Bearer tokens for the OpenAI-compatible HTTP API, each scoped to a company (or
  root) and optionally a single agent.

  A token is a random string prefixed `pepe_`. Only its **SHA-256 hash** is stored in
  the config - the raw token is shown once at creation and never persisted, so a
  leaked config can't be replayed. Verification hashes the presented token and looks
  it up.

  Scope, from narrowest to widest:

    * `agent`   - locked to exactly that agent handle; the request's `model` field is
      ignored, so the token always runs that one agent.
    * `company` - any agent inside that company; a bare `model` name qualifies into it,
      and another company's agent is refused.
    * neither   - the root scope (root agents + bare model connections).
  """

  @prefix "pepe_"

  @doc "Generate a fresh raw token (shown once, never stored)."
  @spec generate() :: String.t()
  def generate do
    @prefix <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
  end

  @doc "Hash a raw token for storage/lookup."
  @spec hash(String.t()) :: String.t()
  def hash(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  @doc "A short, safe fingerprint for display (never the full secret)."
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(raw) when is_binary(raw), do: String.slice(raw, 0, 12) <> "..."

  @doc "Extract a bearer token from an Authorization header value, or nil."
  @spec from_header(String.t() | nil) :: String.t() | nil
  def from_header("Bearer " <> token), do: String.trim(token)
  def from_header("bearer " <> token), do: String.trim(token)
  def from_header(_), do: nil
end
