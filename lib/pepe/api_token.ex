defmodule Pepe.ApiToken do
  @moduledoc """
  Bearer tokens for the OpenAI-compatible HTTP API, each scoped to a project (or
  root) and optionally a single agent.

  A token is a random string prefixed `pepe_`. Only its **SHA-256 hash** is stored in
  the config - the raw token is shown once at creation and never persisted, so a
  leaked config can't be replayed. Verification hashes the presented token and looks
  it up.

  Scope, from narrowest to widest:

    * `agent`   - locked to exactly that agent handle; the request's `model` field is
      ignored, so the token always runs that one agent.
    * `project` - any agent inside that project; a bare `model` name qualifies into it,
      and another project's agent is refused.
    * neither   - the root scope (root agents + bare model connections).

  ## Permissions

  Scope answers *whose* data a token reaches; permissions answer *what it may do* with it.

    * `chat` - may run agents (`/v1/chat/completions`, the WebSocket). Default **true**,
      so every token minted before permissions existed keeps working exactly as it did.
    * `usage` - may read `/v1/usage`. Default **false**, for the same reason from the other
      direction: gaining a token must never silently gain a reader of the billing record.
    * `prices` - which money a usage read is allowed to see: `"billable"` (with the
      project's markup - what the client pays), `"list"` (the tokens at the model's price,
      no markup), or `"all"` (adds `cost` and `margin`, the operator's view). Default
      `"billable"`. This is enforced from the token, never from the request: a client that
      asks for `prices=all` gets its own token's view, not the one it asked for.
    * `usage_content` - may see conversation content (the prompt, tool arguments and tool
      output) in a run's detail. Default **false**: a usage token is for the bill, and a
      bill is not a transcript.

  The two halves are independent on purpose. A billing integration gets
  `chat: false, usage: true`; a plain API client keeps `chat: true, usage: false`, which
  is what it already had.
  """

  @prefix "pepe_"
  @price_views ~w(billable list all)

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

  @doc "The price views a token may be given, widest last."
  @spec price_views() :: [String.t()]
  def price_views, do: @price_views

  @doc """
  A stored token entry's permissions, filled in with the defaults an entry that predates
  them implies (`chat: true`, everything else off). Absence is answered here, once, so no
  caller has to remember which way a missing key falls.
  """
  @spec permissions(map()) :: %{chat: boolean(), usage: boolean(), prices: String.t(), usage_content: boolean()}
  def permissions(entry) when is_map(entry) do
    %{
      chat: Map.get(entry, "chat") != false,
      usage: Map.get(entry, "usage") == true,
      prices: price_view(Map.get(entry, "prices")),
      usage_content: Map.get(entry, "usage_content") == true
    }
  end

  @doc "Normalize a price view, falling back to the narrowest (`\"billable\"`) for anything unknown."
  @spec price_view(term()) :: String.t()
  def price_view(view) when is_binary(view) do
    if view in @price_views, do: view, else: "billable"
  end

  def price_view(_), do: "billable"

  @doc "Extract a bearer token from an Authorization header value, or nil."
  @spec from_header(String.t() | nil) :: String.t() | nil
  def from_header("Bearer " <> token), do: String.trim(token)
  def from_header("bearer " <> token), do: String.trim(token)
  def from_header(_), do: nil
end
