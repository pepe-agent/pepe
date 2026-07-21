defmodule Pepe.Config.Commitment do
  @moduledoc """
  A **commitment** - something said during a conversation that implies a follow-up later:
  the user asking to be reminded ("me lembra de mandar o relatório sexta"), or the agent
  itself promising to check on something ("let me verify that and I'll tell you
  tomorrow"). Extracted automatically after a turn (see `Pepe.Agent.CommitmentExtract`),
  not created by hand.

  `origin_type` decides how it's delivered when due: `"user_reminder"` sends a canned
  message (the same thing `Pepe.Watch` already does); `"agent_promise"` re-runs the
  original agent session so it actually does the thing before replying, instead of just
  parroting the promise back.

  `source_excerpt` is the verbatim sentence the extraction says it came from - kept so a
  low-confidence commitment can be shown to a human with "here's why", and so the
  extraction can be mechanically checked against the real transcript before it's ever
  trusted.
  """

  @derive Jason.Encoder
  defstruct id: nil,
            text: nil,
            source_excerpt: nil,
            due_when: nil,
            due_at: nil,
            # "user_reminder" | "agent_promise"
            origin_type: "user_reminder",
            agent: nil,
            origin: %{},
            confidence: nil,
            # awaiting_confirmation | scheduled | firing | delivered | cancelled | expired
            state: "awaiting_confirmation",
            created_at: nil,
            delivered_at: nil,
            last_error: nil,
            # Fired but delivery failed (origin unreachable, session crashed) - held here
            # for the scheduler's next-tick retry, same shape as a watch's pending delivery.
            pending_delivery: nil,
            # Set the moment state becomes "firing" (see Pepe.Commitments.Scheduler) - an
            # agent_promise's own fulfillment (re-running a real session) can take real time
            # and can crash mid-way, and this is the only record that it was ever attempted.
            firing_at: nil

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      text: map["text"],
      source_excerpt: map["source_excerpt"],
      due_when: map["due_when"],
      due_at: map["due_at"],
      origin_type: map["origin_type"] || "user_reminder",
      agent: map["agent"],
      origin: map["origin"] || %{},
      confidence: map["confidence"],
      state: map["state"] || "awaiting_confirmation",
      created_at: map["created_at"],
      delivered_at: map["delivered_at"],
      last_error: map["last_error"],
      pending_delivery: map["pending_delivery"],
      firing_at: map["firing_at"]
    }
  end
end
