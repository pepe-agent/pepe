# Agents - create, edit, train

An agent is a persona (system prompt) + a model + an allowlist of tools + loop
limits. You manage other agents with the `manage_agent` tool (only agents within your
admin scope - see below).

## Anatomy

- **name**, **model** (a configured connection; blank = default model).
- **persona** - the system prompt. Stored as `SOUL.md` in the agent's workspace
  (`~/.pepe/agents/<name>/`); falls back to the config `system_prompt` seed.
- **tools** - the allowlist. A capability = having its tool. Includes built-ins,
  `mcp__<server>__<tool>` MCP tools, and plugin tools. A new agent defaults to
  every tool enabled - remove the ones you don't want this agent to have,
  rather than having to list everything it should.
- **can_message** - directed routing: which agents it may message.
- **can_manage** - admin scope: which agents it may administer (see below).
- **memory** - `MEMORY.md` / `USER.md` in its workspace.

## Managing an agent (`manage_agent`)

- `list` - agents you may manage.
- `get target: X` - X's definition.
- `create target: X [value: persona]` - a new agent.
- `set_persona target: X value: "..."` - set X's persona (SOUL.md).
- `set_model target: X value: <model>`.
- `add_tool` / `remove_tool target: X value: <tool>` - grant/revoke one tool.
- `remember target: X value: "..."` - append a durable fact to X's memory (train it).

## Admin scope (`can_manage`) - who can configure whom

- **omitted / null** -> the agent may manage only itself.
- **`[]`** -> nobody, not even itself (a locked agent, e.g. client-facing).
- **`["a", "b"]`** -> exactly those agents (add its own name to include itself).
- **`["*"]`** -> every agent (an explicit super-admin).

An agent can only `manage_agent` a target inside its `can_manage`. Authority defaults
to closed. Grant it deliberately (CLI: `mix pepe agent manage ADMIN TARGET`). For the
full admin-agent playbook, read `admin-agents.md`; for agent-to-agent routing read
`routing.md`.

## Complexity-based model routing (`triage_model` / `simple_model`)

An agent can run its own model *most* of the time and drop to a cheaper one when a
chat is clearly simple - saving cost without you thinking about it. Two optional
fields turn it on:

- **`triage_model`** - a configured model connection used to *classify* the first
  message. It runs a fixed, Pepe-authored prompt ("reply with one word: SIMPLE or
  COMPLEX") - not the agent, not the persona, nothing you configure.
- **`simple_model`** - the connection to drop to when the verdict is SIMPLE.

Both must be set - triage is skipped entirely if either is missing, since there'd be
nowhere to switch to. Note the framing is a *downgrade*, not an upgrade: the agent's
own `model` is treated as the good default, and SIMPLE downgrades away from it.

How it behaves:

- It only ever fires on a **session's first turn** - never again for the rest of that
  session, and never when an explicit `/model` override is already in play (a manual
  switch always wins).
- A **SIMPLE** verdict downgrades this turn to `simple_model` **and makes it stick** -
  every later turn in the session stays on the cheap model too.
- **COMPLEX**, or **any triage failure** (unknown model, network error, or slower than
  the ~6s timeout), just proceeds on the agent's own model unchanged. It is fail-open
  by design: triage is a best-effort optimization and never blocks or delays a turn
  beyond its short timeout.

Configure it when creating the agent:

```bash
mix pepe agent add support --model gpt-4o --triage-model gpt-4o-mini --simple-model gpt-4o-mini
```

Here a cheap model both judges the message and answers it when the chat is simple,
while anything needing real reasoning runs on `gpt-4o`.

### A decision-only connection for `triage_model`

`triage_model` (and the mid-turn check of `midrun_fold`) may be a *decision-only* connection,
for example TypeSafe Jev (provider "typesafe", `mix pepe model add NAME` and pick it, or the
dashboard Models page). It does not chat: it picks one of a few options and returns how sure it
is, which makes it the cheapest and fastest way to sort. It is shown with a "Decisions only"
label and is offered only for `triage_model`; it is never valid as an agent's `model`,
`simple_model`, `utility_model`, a backup model, or the install default.

Set it for a user who asks to make sorting cheaper: `manage_agent` `set_triage_model` (an empty
`value` turns it off), or `mix pepe agent add NAME --triage-model CONNECTION`. Tell them to give
the connection a backup chat model on the Models page ("Add a backup model"): when the connection
fails (no credit, wrong key, down, slow) or is unsure about the cheap option, that backup decides
as a chat triage model always did, and with no backup answering the message counts as complex, so
a conversation is never blocked by it. `mix pepe model test NAME` makes a real decision to check it.

## Mid-turn folding (`midrun_fold`)

Normally a message that arrives while a turn is already running just waits its turn in
the queue. With `midrun_fold: true`, a message that arrives mid-turn is classified first:
is it a correction/clarification of the turn already in flight ("wait, make it 3pm
instead"), or something unrelated? A correction is steered straight into the running turn
(same mechanism as `/inline`) instead of waiting; anything else - including any
classifier failure or timeout - queues exactly as it always has.

The classification call prefers `triage_model` if one is set (cheap, reuses the same
connection complexity routing uses, so it costs nothing extra to set up if that's already
on). Without a `triage_model` it falls back to the agent's own `model` instead of doing
nothing - meaning `midrun_fold` works standalone, but every message that arrives mid-turn
now costs an extra call on that agent's own model to classify it. Set a `triage_model`
too if that cost matters.

## Offering to change agent when the subject changes (`topic_reroute`)

A conversation sticks to whichever agent it was last routed to, so a user who moves on to
another subject stays with the wrong agent until `/new`. With `topic_reroute: true` on an
agent, that agent is offered a `hand_back` tool whenever this conversation is with it and
not with the channel's own agent (the one `/new` returns to, usually a routing agent). When
a message is clearly outside what the agent covers, it calls `hand_back`, which asks the
user yes or no (real buttons where the channel has them). On yes the conversation returns
to the channel's own agent and the user's message is re-sent to it, so it routes the
message without the user repeating it. On no the agent keeps answering and does not offer
again until the subject changes again.

Turn it on for a user who asks to stop getting stuck with the wrong agent: `manage_agent`
`set_flag` with `topic_reroute`, or `mix pepe agent add NAME --topic-reroute`. The agent only
judges its own scope, so there is nothing else to configure and no list of other agents to
keep. It does nothing on the channel's own agent, on a channel that locks agent switching,
and a side question the agent can answer itself should just be answered. A routing agent
whose `switch_agent` call is for a message that was itself a request should pass
`forward_message: true` so the target gets that message at once.
