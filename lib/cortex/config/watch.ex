defmodule Cortex.Config.Watch do
  @moduledoc """
  A **watch** — a one-shot, durable "check X and notify me when it happens".

  Created on demand (the agent calls `notify_when` when you ask), it lives on disk so
  it survives a restart and the originating session closing, and it **stops once it
  fires**. Two cost tiers, chosen at creation:

    * `trigger` — how the condition is re-checked every interval:
      * `%{"type" => "probe", "command" => "curl -sf https://x", "success" => "exit_zero"}`
        — a cheap shell probe, **no LLM per check** (success = exit 0, or
        `%{"contains" => "..."}` against stdout).
      * `%{"type" => "agent", "prompt" => "has the deploy finished?"}` — re-ask the
        agent when the condition needs judgement (one LLM call per check).
    * `on_fire` — what to send when it fires:
      * `%{"type" => "template", "text" => "✅ site is back"}` — a fixed message, no LLM.
      * `%{"type" => "agent", "prompt" => "summarise the deploy result"}` — the agent
        composes the message (one LLM call, once).

  `origin` records where to deliver — `%{"channel" => "telegram", "chat_id" => ...}` —
  captured when the watch is created, so the reply lands on the channel you asked from
  even after a restart.
  """

  @derive Jason.Encoder
  defstruct id: nil,
            description: nil,
            agent: nil,
            trigger: %{},
            on_fire: %{},
            origin: %{},
            interval_s: 120,
            max_checks: 720,
            checks: 0,
            # pending | paused | done | expired | cancelled
            state: "pending",
            created: nil,
            last_check: nil,
            next_check: nil,
            last_error: nil,
            # Notification text held here when the origin channel was unreachable.
            pending_delivery: nil

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      description: map["description"],
      agent: map["agent"],
      trigger: map["trigger"] || %{},
      on_fire: map["on_fire"] || %{},
      origin: map["origin"] || %{},
      interval_s: map["interval_s"] || 120,
      max_checks: map["max_checks"] || 720,
      checks: map["checks"] || 0,
      state: map["state"] || "pending",
      created: map["created"],
      last_check: map["last_check"],
      next_check: map["next_check"],
      last_error: map["last_error"],
      pending_delivery: map["pending_delivery"]
    }
  end
end
