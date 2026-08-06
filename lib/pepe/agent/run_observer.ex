defmodule Pepe.Agent.RunObserver do
  @moduledoc """
  Additive, observation-only extension point for watching an agent's tool-calling loop
  (`Pepe.Agent.Runtime`) from outside - see `Pepe.Agent.RunObservers` for how it's
  dispatched and isolated.

  NOT to be confused with `Pepe.Hooks`: that's the synchronous, opt-in, text-mutating
  PII-redaction pipeline threaded through the message flow. A run observer is the
  opposite in every way that matters here - always-on for whatever's installed,
  asynchronous, and can only watch, never touch. Two different mechanisms, deliberately
  not sharing a name.

  `subscriptions/0` names which event types this observer wants - any of the atoms
  `Pepe.Agent.Runtime`'s moduledoc lists (`:tool_call`, `:tool_result`, `:done`, `:error`,
  ...), plus the synthetic `:run_start`/`:run_end` bookends `Pepe.Agent.RunObservers`
  itself emits. `handle_event/3` is called once per subscribed event, in the order the
  turn produced them, for the run this instance was attached to - `event` is the type atom,
  `payload` is the full event tuple (`{:tool_call, name}` note: WITHOUT its raw
  arguments - see `Pepe.Agent.RunObservers`'s moduledoc for why), `meta` carries at least
  `:ts` (monotonic milliseconds). The return value is ignored.

  An observer never sees message history - only these event payloads, the same view
  `Pepe.Trace`/a live surface's `:on_event` already gets.
  """

  @callback name() :: String.t()
  @callback subscriptions() :: [atom()]
  @callback handle_event(event :: atom(), payload :: term(), meta :: map()) :: any()
end
