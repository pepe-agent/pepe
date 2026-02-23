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
            # standard cron expression, e.g. "0 8 * * *"
            schedule: nil,
            timezone: "Etc/UTC",
            # optional model connection override; nil = the agent's model
            model: nil,
            # where to send the result: "telegram:<chat_id>" | "log"
            deliver: "log",
            enabled: true,
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
      schedule: map["schedule"],
      timezone: map["timezone"] || "Etc/UTC",
      model: map["model"],
      deliver: map["deliver"] || "log",
      enabled: Map.get(map, "enabled", true),
      last_run: map["last_run"],
      last_result: map["last_result"]
    }
  end
end
