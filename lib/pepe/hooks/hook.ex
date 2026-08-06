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

  Additive, plugin-discoverable via `Pepe.Plugins.implementing/1` - `Pepe.Hooks.registry/0`
  merges installed plugins with the four built-ins above (a built-in wins any name clash,
  same rule `Pepe.Tools` uses). A plugin hook is how a context-compaction or
  content-redaction plugin mutates the conversation for real: this pipeline already runs
  synchronously, inline, on the hot `:inbound`/`:outbound`/`:tool_result` path - unlike
  `Pepe.Agent.RunObserver`, which is deliberately read-only. Each hook in the chain sees the
  *previous* hook's already-mutated text, in order - a sequential chain, not a fan-out, so a
  later hook always builds on what an earlier one already changed. Fail-open (the existing
  contract, unchanged): a hook that raises falls back to the input text rather than breaking
  the turn - mutation gone wrong should degrade to "as if this hook weren't installed", not
  deny anything (that's `Pepe.Permissions.Policy`'s job, which is fail-*closed* on purpose,
  being a fundamentally different kind of veto power).
  """

  @type stage :: :inbound | :outbound | :learn | :tool_result

  @typedoc "A reversible mapping entry: a pseudonym/token and the real value it hides."
  @type mapping :: %{optional(String.t()) => any()}

  @doc "The registry key this hook is selected by (an agent's own `hooks` list, `mix pepe hook`)."
  @callback name() :: String.t()

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
