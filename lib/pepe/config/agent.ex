defmodule Pepe.Config.Agent do
  @moduledoc """
  An agent definition: a persona (system prompt) bound to a model connection,
  with an allowlist of tools and loop limits.
  """

  # The seed persona an agent gets before the user defines its own. Treated as
  # "no identity yet" by Pepe.Agent.Workspace, which swaps in onboarding guidance.
  @default_prompt "You are Pepe, a helpful AI agent."

  @derive Jason.Encoder
  defstruct id: nil,
            # The agent's stable identity is its `id`; `name` is a mutable label and `project` is
            # the owning project's id. `.name` as read back from Pepe.Config is the derived display
            # **handle** (`<project-slug>/<name>`), so existing callers keep seeing a handle; the
            # bare label lives in `bare` and the owning project in `project`.
            name: nil,
            bare: nil,
            project: nil,
            description: nil,
            model: nil,
            system_prompt: @default_prompt,
            tools: [],
            auto_approve: [],
            can_message: [],
            # Which agents this one may administer (see Pepe.Config.can_manage?/2):
            # nil = itself only, [] = nobody (not even itself), [names] = exactly those,
            # ["*"] = everyone.
            can_manage: nil,
            # Privacy/transform hooks this agent runs on the message flow (redaction,
            # ...), by name - see `Pepe.Hooks`. Empty = none (raw, the default).
            hooks: [],
            max_iterations: 12,
            temperature: nil,
            # Per-agent override of the model connection's own `fallbacks` chain (see
            # Pepe.Config.Model): nil = inherit the connection's chain (the default),
            # [] = explicitly no fallback for this agent even if the connection has
            # one, [names] = use exactly this chain instead. See
            # Pepe.Config.model_chain_for_agent/1.
            fallbacks: nil,
            # Complexity-based model routing: nil = off (the default). When set, a raw
            # classification call to this model connection judges a session's first
            # message before the real turn starts (a fixed, Pepe-authored prompt - no
            # agent, no persona to configure). This agent's own `model` is treated as
            # the "good" default; a SIMPLE verdict downgrades the session to
            # `simple_model` (and keeps it there) to save cost, instead of the more
            # common "upgrade on complex" framing - most agents are already set up on
            # a model worth defaulting to. A best-effort optimization, never a
            # blocking dependency: any triage failure (bad name, network error,
            # timeout) just means the turn proceeds on this agent's own model exactly
            # as if triage weren't configured at all.
            triage_model: nil,
            # The model connection to downgrade to (and stay on, for the rest of the
            # session) when `triage_model` judges a chat simple. Only meaningful when
            # `triage_model` is set - triage is skipped entirely if this is unset,
            # since there would be nowhere to switch to on a SIMPLE verdict.
            simple_model: nil,
            # The cheap model connection for the small talk the agent has with itself
            # rather than with the user: naming a conversation, and whatever chrome comes
            # after it. Not for anything whose output the agent then has to *reason from* -
            # a summary written badly poisons every turn that reads it, so compaction
            # deliberately stays on the agent's own model. nil = use the agent's own model.
            # See Pepe.Agent.Utility.
            utility_model: nil,
            # Skip the project's monthly customer-message cap for this agent (see
            # Pepe.Config.project_message_limit/1) - an always-on agent (e.g. an
            # escalation/on-call agent) that must never be throttled by it. Doesn't
            # affect the project's separate spend cap (over_budget?/1).
            exempt_message_limit: false,
            # Let this agent ACT on content from outside (a document a client sent, a page a
            # tool fetched). Off by default, and the default is the safe one: normally, once a
            # run has taken in a stranger's content, the agent's pre-approved tools go back to
            # asking, so an injected "ignore your instructions and run this" cannot quietly
            # fire a tool this agent was trusted with (see Pepe.Permissions). Turn this on only
            # for an agent you have decided to trust to act on what strangers send it - which
            # is a real decision, not a convenience: it reopens exactly that path. Reading and
            # answering never needed it; this is only for a document that must trigger an
            # action on the system.
            trust_untrusted_content: false

  @type t :: %__MODULE__{}

  @doc "The default seed persona - the marker for an agent with no identity set yet."
  @spec default_prompt() :: String.t()
  def default_prompt, do: @default_prompt

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      name: map["name"],
      bare: map["bare"],
      project: map["project"],
      description: map["description"],
      model: map["model"],
      system_prompt: map["system_prompt"] || @default_prompt,
      tools: map["tools"] || [],
      auto_approve: map["auto_approve"] || [],
      can_message: map["can_message"] || [],
      # Preserve nil (the "itself only" default) vs [] (nobody) - don't coalesce.
      can_manage: map["can_manage"],
      hooks: map["hooks"] || [],
      max_iterations: map["max_iterations"] || 12,
      temperature: map["temperature"],
      # Preserve nil (inherit the connection's chain) vs [] (explicitly none).
      fallbacks: map["fallbacks"],
      triage_model: map["triage_model"],
      simple_model: map["simple_model"],
      utility_model: map["utility_model"],
      exempt_message_limit: map["exempt_message_limit"] || false,
      trust_untrusted_content: map["trust_untrusted_content"] || false
    }
  end
end
