defmodule Pepe.Config.Cron do
  @moduledoc """
  A scheduled task ("cron"): run an agent with a **self-contained** prompt on a
  recurring schedule, and deliver the result somewhere.

  Because a cron fires in a **fresh session** (no memory of any chat), its `prompt`
  must include everything the agent needs - the domain context, what to check, the
  window, the timezone. The agent bakes that in when it creates the job.
  """

  @derive Jason.Encoder
  defstruct id: nil,
            name: nil,
            agent: nil,
            prompt: nil,
            # "prompt" (run the agent on `prompt`), "consolidate" (a memory-housekeeping pass
            # over the agent's standing memory, ignoring `prompt`), or "flow" (replay a
            # Pepe.Flow promoted for this agent, named in `flow` below, calling no model at
            # all - ignoring `prompt` the same way "consolidate" does).
            kind: "prompt",
            # Only meaningful when kind == "flow": the Pepe.Flow's name (looked up under
            # this cron's own `agent`).
            flow: nil,
            # standard cron expression, e.g. "0 8 * * *"
            schedule: nil,
            timezone: "Etc/UTC",
            # optional model connection override; nil = the agent's model
            model: nil,
            # where to send the result: "telegram:<chat_id>" | "log"
            deliver: "log",
            enabled: true,
            # Run this job again even when the previous run of it is still going. False, and
            # deliberately: a cron here is an agent turn, not an idempotent script. It costs a
            # model call, it has side effects, and every run of it shares one agent workspace,
            # so a job that outgrows its own schedule would pile up, be billed twice, deliver
            # twice, and have two runs writing over each other. It is skipped instead, and the
            # skip is recorded, which is how you find out the job is too slow for its schedule.
            # Set this only where concurrency is genuinely what you want.
            overlap: false,
            last_run: nil,
            last_result: nil

  @type t :: %__MODULE__{}

  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["id"],
      name: map["name"],
      agent: map["agent"],
      prompt: map["prompt"],
      kind: map["kind"] || "prompt",
      flow: map["flow"],
      schedule: map["schedule"],
      timezone: map["timezone"] || "Etc/UTC",
      model: map["model"],
      deliver: map["deliver"] || "log",
      enabled: Map.get(map, "enabled", true),
      overlap: Map.get(map, "overlap", false),
      last_run: map["last_run"],
      last_result: map["last_result"]
    }
  end
end
