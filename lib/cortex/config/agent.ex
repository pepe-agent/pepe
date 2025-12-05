defmodule Cortex.Config.Agent do
  @moduledoc """
  An agent definition: a persona (system prompt) bound to a model connection,
  with an allowlist of tools and loop limits.
  """

  @derive Jason.Encoder
  defstruct name: nil,
            description: nil,
            model: nil,
            system_prompt: "You are Cortex, a helpful AI agent.",
            tools: [],
            auto_approve: [],
            max_iterations: 12,
            temperature: nil

  @type t :: %__MODULE__{}

  def from_map(map) when is_map(map) do
    %__MODULE__{
      name: map["name"],
      description: map["description"],
      model: map["model"],
      system_prompt: map["system_prompt"] || "You are Cortex, a helpful AI agent.",
      tools: map["tools"] || [],
      auto_approve: map["auto_approve"] || [],
      max_iterations: map["max_iterations"] || 12,
      temperature: map["temperature"]
    }
  end
end
