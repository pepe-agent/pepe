defmodule Cortex.Config.Agent do
  @moduledoc """
  An agent definition: a persona (system prompt) bound to a model connection,
  with an allowlist of tools and loop limits.
  """

  # The seed persona an agent gets before the user defines its own. Treated as
  # "no identity yet" by Cortex.Agent.Workspace, which swaps in onboarding guidance.
  @default_prompt "You are Cortex, a helpful AI agent."

  @derive Jason.Encoder
  defstruct name: nil,
            description: nil,
            model: nil,
            system_prompt: @default_prompt,
            tools: [],
            auto_approve: [],
            can_message: [],
            # Which agents this one may administer (see Cortex.Config.can_manage?/2):
            # nil = itself only, [] = nobody (not even itself), [names] = exactly those,
            # ["*"] = everyone.
            can_manage: nil,
            max_iterations: 12,
            temperature: nil

  @type t :: %__MODULE__{}

  @doc "The default seed persona — the marker for an agent with no identity set yet."
  @spec default_prompt() :: String.t()
  def default_prompt, do: @default_prompt

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"],
      description: map["description"],
      model: map["model"],
      system_prompt: map["system_prompt"] || @default_prompt,
      tools: map["tools"] || [],
      auto_approve: map["auto_approve"] || [],
      can_message: map["can_message"] || [],
      # Preserve nil (the "itself only" default) vs [] (nobody) — don't coalesce.
      can_manage: map["can_manage"],
      max_iterations: map["max_iterations"] || 12,
      temperature: map["temperature"]
    }
  end
end
