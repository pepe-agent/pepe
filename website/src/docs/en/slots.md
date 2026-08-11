---
title: Slots
description: Let one installed plugin take over an exclusive extension point, like memory search or web search, instead of the built-in, with automatic fallback if it misbehaves.
---

Some jobs in Pepe can only have one owner at a time: something has to be *the* thing that
answers a memory search, or *the* place a shell command runs. A **slot** is that kind of
extension point, with exactly one occupant at a time, unlike a [plugin](/docs/plugins) tool
or channel, where many can coexist. Memory search is a slot: either the built-in search
answers, or one installed plugin you named takes over. Never both, and never a silent
pile-up of several plugins answering the same question.

The built-in occupant isn't special-cased code; it's just the default when nothing is
configured. Swapping a slot's occupant is a configuration change, never a code change. And
if the configured occupant crashes, times out, or returns something malformed, Pepe falls
back to the built-in for that one call and logs it: a misbehaving occupant can lower the
quality of an answer, but it never breaks a conversation.

## The slots today

| Slot | Built-in occupant | What it answers |
|---|---|---|
| `memory` | Case-insensitive substring search over `MEMORY.md`/`USER.md`/`people.md` | The `memory_search` tool |
| `web_search` | DuckDuckGo's Instant Answer API | The `web_search` tool |
| `sandbox` | Runs directly, or through the configured wrapper script (see [Security](/docs/security)) | The `bash`/`run_script` tools: *where* a shell command actually runs |
| `model_select` | `Pepe.Config.model_chain_for_agent/1`'s static chain | Which model chain a run uses |
| `heartbeat_interval` | Always allows a due pulse | Whether a due Telegram heartbeat pulse is allowed to fire |
| `compaction` | Summarizes the middle of a long conversation with the model itself | How a long conversation gets condensed to fit the context window |
| `harness` | The agent's own conversation loop (`Pepe.Agent.Runtime`) | The *entire* turn: not one call, the whole reasoning loop |

One slot deserves a special word before you pin anything to it: `harness`. A plugin pinned
there takes over driving the whole task, and it acts with the conversation's own
permissions, so only install one from a source you trust. The details are in the Harness
section below.

## Managing slots

```bash
pepe slot list                 # every slot, its current occupant, and its default
pepe slot set memory NAME      # pin a slot to an installed plugin's own name
pepe slot clear memory         # revert to the built-in
```

`pepe slot list` flags a configured occupant that can't actually answer anymore (removed,
renamed, or it never claimed the slot) as "using the default instead". `pepe doctor`
checks for the same thing, so a stale slot setting doesn't go unnoticed.

## Scoping a slot to one agent or project

`pepe slot set` above pins a slot for the whole installation: every agent gets the same
occupant. An agent can override that for itself:

```bash
pepe agent add support --slots memory:example_memory
```

or directly in `config.json`:

```json
{
  "agents": {
    "support": { "slots": { "memory": "example_memory" } }
  }
}
```

A project can set its own default for every agent in it, the same shape `default_hooks`
already uses:

```json
{
  "projects": {
    "acme": { "default_slots": { "memory": "example_memory" } }
  }
}
```

Resolution is agent override → project default → the installation-wide setting → the
built-in. One agent in a project can run a different memory backend than every other agent
and project, without a global change nobody else asked for.

## Writing a slot plugin

A plugin claims a slot by exporting the slot's function set **plus** `slot/0`, returning
the exact slot name - that's the disambiguator, the same way a tool's `name/0` keeps it
from being confused with another tool.

### Memory

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # always "memory"
@callback search(agent_name :: String.t(), query :: String.t(), opts :: keyword()) ::
            {:ok, [%{file: String.t(), entry: String.t(), score: number() | nil, source: String.t() | nil}]} |
            {:error, term()}
```

`opts` may carry `:limit` and a `:mode` hint (`:keyword | :vector | :hybrid`) - the
built-in ignores `:mode`; a richer backend (a vector store) is free to use it. `index/1`
is optional, for a backend that maintains its own store and needs to rebuild it.

### Web search

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # always "web_search"
@callback search(query :: String.t(), opts :: keyword()) ::
            {:ok, [%{title: String.t() | nil, url: String.t() | nil, snippet: String.t()}]} |
            {:error, term()}
```

### Sandbox

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # always "sandbox"
@callback run(program :: String.t(), argv :: [String.t()], opts :: keyword()) ::
            {:ok, {output :: String.t(), exit_status :: non_neg_integer()}} | {:error, term()}
```

`opts` already has its `:env` stripped of every secret Pepe holds by the time this runs
(see [Security](/docs/security)'s "the agent's shell does not inherit Pepe's secrets") -
true no matter which occupant answers. This is the one slot where `bash`'s own per-call
`timeout_ms` (not the slot's own generous 5-minute ceiling) is the real deadline for the
built-in; a plugin occupant should still return promptly, since the slot ceiling is a
backstop, not a budget to use up.

### Model selection

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # always "model_select"
@callback chain_for(agent :: map()) :: {:ok, [Pepe.Config.Model.t()]} | {:error, term()}
```

Called once per turn (`Pepe.Agent.Runtime.do_run/3`), before the model chain is walked -
never per tool call. Returning `[]` is a valid answer ("no model configured"), not a
malformed one. An explicit `:model` passed by the caller (a pinned test, a harness)
bypasses this slot entirely - it means exactly that model, not whatever policy an occupant
would apply.

A natural use: swap to a cheaper model once a project's spend gets close to its cap.
`Pepe.Usage.tier/1` reports `:normal | :low_compute | :critical | :dead` from the same
ratio the spend cap itself uses (see [Usage and billing](/docs/billing)), so an occupant
doesn't have to re-derive it.

### Heartbeat pacing

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # always "heartbeat_interval"
@callback allowed?(project :: String.t() | nil) :: {:ok, boolean()} | {:error, term()}
```

One more veto on top of a Telegram bot's own static `heartbeat_minutes`/hour schedule,
which this never touches: called only once that schedule already says a pulse is due,
right before it actually fires. The built-in always allows. A plugin here can skip a pulse
that's otherwise due - `Pepe.Usage.tier/1` is the obvious signal, e.g. skip while a
project is `:critical` or `:dead`.

### Compaction

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # always "compaction"
@callback compact(messages :: [map()], model :: map(), agent :: map() | nil, session_key :: String.t() | nil) ::
            {:ok, [map()]}
```

A plugin here decides how a long conversation gets condensed to fit the model's context
window - a different summarization strategy, a non-LLM heuristic, whatever it wants. It
should always return `{:ok, messages}`, even when it decides not to condense anything (the
built-in never fails outright; a crash/timeout still degrades to the built-in for that call).

**Building one, step by step:**

1. Write a module implementing `name/0`, `slot/0` (returning `"compaction"`), and
   `compact/4`. Below is a simple non-LLM strategy: once the conversation passes a message
   count, drop everything except the system prompt and the most recent exchanges, with
   a one-line marker instead of a real summary - cheaper and instant, at the cost of
   actually forgetting the middle rather than condensing it.

   ```elixir
   defmodule TailOnlyCompaction do
     # No dedicated @behaviour module ships for this slot - name/0, slot/0, compact/4 are
     # matched by shape, the same way memory/web_search plugins are.
     def name, do: "tail_only_compaction"
     def slot, do: "compaction"

     @keep_last 12

     def compact(messages, _model, _agent, _session_key) do
       {system, rest} = Enum.split_with(messages, &(&1["role"] == "system"))

       if length(rest) <= @keep_last do
         {:ok, messages}
       else
         marker = %{"role" => "user", "content" => "<system-reminder>\nEarlier turns were dropped to fit the context window (tail_only_compaction).\n</system-reminder>"}
         {:ok, system ++ [marker | Enum.take(rest, -@keep_last)]}
       end
     end
   end
   ```

2. Save it as `~/.pepe/plugins/tail_only_compaction.exs` (or install it from wherever it
   lives: `pepe plugin install ./tail_only_compaction.exs`).
3. Point the `compaction` slot at it - installation-wide, or for one agent/project only:

   ```bash
   pepe slot set compaction tail_only_compaction   # every agent
   pepe agent add support --slots compaction:tail_only_compaction  # just this one
   ```

4. Confirm it's live: `pepe slot list` shows the occupant; a crash or timeout falls back
   to the built-in for that call and is visible there too.

### Harness

```elixir
@callback name() :: String.t()
@callback slot() :: String.t()          # always "harness"
@callback run(agent :: map(), messages :: [map()], opts :: keyword()) ::
            {:ok, final_content :: String.t(), all_messages :: [map()]} | {:error, term()}
```

This is the one slot that doesn't get the isolation every other one does: a harness
occupant runs in the turn's own process, not a supervised `Task`, because it needs to call
back into Pepe's own permission gate and tool execution exactly as the built-in loop does -
those read turn state (whether the run has taken in outside content, what's already been
approved) from that process, which an isolated `Task` deliberately can't see. Pinning a
plugin here hands it the *whole* turn: the permission gate, loop-guard, and context
compaction are all the built-in loop's own machinery, and none of it applies automatically
to a turn a harness plugin is driving - a well-behaved one calls `opts[:on_event]` itself so
a live chat surface keeps streaming, and can call `Pepe.Trace.event/1`/
`Pepe.Agent.RunObservers.notify/1` for full trace/observer fidelity if it wants it. A
crashing/timing-out harness returns an error rather than silently re-running the turn on the
built-in loop - a harness that's already taken real action (sent a reply, run a tool)
through its own means shouldn't risk doing it twice.

**Building one, step by step:**

1. Write a module implementing `name/0`, `slot/0` (returning `"harness"`), and `run/3`.
   The example below shells out to an external command and returns its output as the
   whole reply - the smallest real harness, standing in for "delegate to a different
   agent CLI":

   ```elixir
   defmodule ExternalCliHarness do
     @behaviour Pepe.Agent.Harness

     @impl true
     def name, do: "external_cli_harness"

     @impl true
     def slot, do: "harness"

     @impl true
     def run(agent, messages, opts) do
       prompt = messages |> List.last() |> Map.get("content", "")

       case System.cmd("my-agent-cli", ["--prompt", prompt], stderr_to_stdout: true) do
         {output, 0} ->
           content = String.trim(output)
           if fun = opts[:on_event], do: fun.({:assistant_delta, content})
           {:ok, content, messages ++ [%{"role" => "assistant", "content" => content}]}

         {output, _status} ->
           {:error, {:external_cli_failed, output}}
       end
     end
   end
   ```

   Calling `opts[:on_event]` with `{:assistant_delta, content}` is what makes a live
   surface (the CLI, the dashboard chat) actually show the reply as it streams in - see
   the moduledoc note above. Skip it and the reply still returns correctly, it just
   won't render live on a streaming surface.

2. Save it as `~/.pepe/plugins/external_cli_harness.exs` and install it:
   `pepe plugin install ~/.pepe/plugins/external_cli_harness.exs`.
3. Pin the `harness` slot to it - this is a bigger decision than most slots, since it
   hands the plugin the whole turn (see above), so scoping it to one agent while testing
   is usually the right first move:

   ```bash
   pepe agent add cli-backed --slots harness:external_cli_harness  # just this agent
   pepe slot set harness external_cli_harness                      # every agent
   ```

4. Try it: `pepe run cli-backed "hello"` never reaches the model at all - the reply comes
   straight from `external_cli_harness`.

A minimal slot-plugin example, saved as `~/.pepe/plugins/example_memory.exs`:

```elixir
defmodule ExampleMemory do
  @behaviour Pepe.Memory.Backend

  def name, do: "example_memory"
  def slot, do: "memory"

  def search(_agent_name, _query, _opts), do: {:ok, []}
end
```

```bash
pepe plugin install ~/.pepe/plugins/example_memory.exs
pepe slot set memory example_memory
```

The `web_search` tool's own untrusted-content wrapping (see [Security](/docs/security))
stays in the tool no matter which backend occupies the slot - a slot backend returns plain
structured results, not text; the trust boundary is drawn once, in core.

## What isn't a slot

Two other extension points look similar but are additive, not exclusive, because more
than one occupant genuinely needs to coexist:

- **A model protocol adapter** (a plugin implementing `Pepe.LLM.Adapter` for a provider
  whose chat protocol isn't OpenAI-compatible - the same role the built-in Responses/
  Messages adapters play) registers under its own `api` string; several protocols run at
  once, one per model connection. A plugin can never override `"openai-responses"` or
  `"anthropic-messages"`.
- **A persistent-connection chat channel** (a plugin implementing `Pepe.Gateways.Channel`
  - for a platform like Discord or Matrix that needs a long-lived websocket, not just an
  inbound webhook) runs alongside every other channel, including Telegram, in its own
  supervised crash domain so a misbehaving one can't take the others down with it. See
  [Plugins](/docs/plugins) for the webhook-based `Pepe.Webhooks.Provider` shape most
  channel plugins should reach for first - a persistent channel is for the platforms a
  webhook genuinely can't cover.
- **A realtime audio provider** (`Pepe.Realtime.Provider`) and **a plugin's own HTTP
  route** (`Pepe.PluginRoute`) are both additive too, and both covered in
  [Plugins](/docs/plugins) - several of either can be installed at once, and a client (or
  the operator, for a route) picks which one by name, unlike a slot's single occupant.
