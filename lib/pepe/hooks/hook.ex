defmodule Pepe.Hooks.Hook do
  @moduledoc """
  The contract a message-flow hook implements - a transform plugged into the
  conversation at defined points, most commonly PII redaction. A hook can run:

    * `:inbound`  - on the user's text **before** the agent/model sees it (so PII
      never reaches an external provider);
    * `:outbound` - on the agent's reply **before** it's sent back (e.g. restore
      pseudonyms to real values);
    * `:learn`    - on text about to feed the memory/skill review.

  All hooks share one contract, so `pii_redact` (regex), `llm_redact` (a local
  model), `presidio`/`http_redact` (HTTP) compose in the same pipeline and feed the
  same reversible map. `settings` is this hook's global config (from
  `Pepe.Config` `\"hooks\"`); `ctx` carries the running `:map` (pseudonym -> real)
  and the `:agent`/`:session`.
  """

  @type stage :: :inbound | :outbound | :learn

  @typedoc "A reversible mapping entry: a pseudonym/token and the real value it hides."
  @type mapping :: %{optional(String.t()) => any()}

  @doc "Which stages this hook runs at."
  @callback stages() :: [stage()]

  @doc """
  Transform `text` at `stage`. Returns the (possibly unchanged) text and any new
  reversible-map entries to remember (merged into the session map, used to restore
  on `:outbound`). Must never raise - a hook failure falls back to the input text.
  """
  @callback run(stage(), text :: String.t(), settings :: map(), ctx :: map()) ::
              {:ok, String.t()} | {:ok, String.t(), [mapping()]}

  @doc "The config fields this hook accepts - drives the dashboard form and the AI generator."
  @callback config_schema() :: [map()]

  @optional_callbacks config_schema: 0
end
