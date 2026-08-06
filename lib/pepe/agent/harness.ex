defmodule Pepe.Agent.Harness do
  @moduledoc """
  The `harness` slot's contract (see `Pepe.Slots`): a plugin that takes over the entire
  turn - not one tool, not one model call, the whole reasoning loop - the same way
  `Pepe.Agent.Runtime`'s own `loop/7` does today. The obvious use is delegating a turn to
  an external agent CLI (a different model provider's own coding agent, say) that owns its
  own session protocol end to end, rather than driving it through Pepe's own tool-calling
  shape.

  This is the one slot `Pepe.Agent.Runtime` does NOT dispatch through `Pepe.Slots.Guard`
  (see `Pepe.Agent.Runtime.run_via_harness/3` for why) - a harness occupant runs in the
  turn-owning process, not an isolated `Task`, and inherits the real trust level of a tool,
  not the arm's-length isolation `memory`/`web_search`/`sandbox`/`compaction` occupants
  get. Pinning a plugin to this slot (`mix pepe slot set harness NAME`, or an agent's own
  `slots` override) hands that plugin the whole turn: `Pepe.Permissions`'s gate,
  `Pepe.Agent.LoopGuard`'s stuck-loop detection, `Pepe.Agent.Compaction`'s context
  management, and the model failover chain are all `Pepe.Agent.Runtime`'s own machinery -
  a harness plugin that wants any of that has to call it itself; none of it applies
  automatically to a turn a harness plugin is driving.

  `run/3` gets the exact same arguments `Pepe.Agent.Runtime.run/3` does, and must return
  the exact same shape: `{:ok, final_content, all_messages}` or `{:error, reason}`. A
  well-behaved harness still calls `opts[:on_event]` for the lifecycle events described in
  `Pepe.Agent.Runtime`'s own moduledoc, so the calling surface's live UI (a streaming chat
  reply, a Telegram "thinking..." indicator) keeps working - `Pepe.Agent.Runtime` cannot
  inject those into a loop it isn't the one running. Likewise, `Pepe.Trace.event/1` and
  `Pepe.Agent.RunObservers.notify/1` are both ordinary public calls a harness can make
  itself for full trace/observer fidelity; `Pepe.Agent.Runtime` only wraps the run as a
  whole (`Pepe.Trace.start/finish`, `RunObservers.attach/finish`), which happens
  regardless of which harness ran it.

  `degrade: :error` (see `Pepe.Slots.definitions/0`) only governs a CALL that reaches
  `run/3` and then fails - it says nothing about `Pepe.Slots.occupant/2`'s own, separate
  resolution step. A pinned harness that fails to *load* at all (a Sentinel `:danger`
  verdict on a changed file, a compile timeout, a deleted plugin) is invisible to that
  guarantee: `occupant/2` simply can't find it, logs a warning, and falls back to
  `Pepe.Agent.Runtime` itself - the builtin loop silently runs where an operator who
  pinned a harness for a real policy reason (not just a feature choice) might expect a
  hard failure instead. Harmless with respect to the double-execution risk `degrade:
  :error` exists for (an unloaded plugin never acted), but worth knowing: `mix pepe slot
  list`/`pepe doctor` is how to notice a harness pin that has quietly stopped resolving.
  """

  alias Pepe.Agent.Runtime
  alias Pepe.Config.Agent

  @callback name() :: String.t()
  @callback slot() :: String.t()
  @callback run(agent :: Agent.t(), messages :: [map()], opts :: Runtime.opts()) ::
              {:ok, String.t(), [map()]} | {:error, term()}
end
