# Agents - create, edit, train

An agent is a persona (system prompt) + a model + an allowlist of tools + loop
limits. You manage other agents with the `manage_agent` tool (only agents within your
admin scope - see below).

## Anatomy

- **name**, **model** (a configured connection; blank = default model).
- **persona** - the system prompt. Stored as `SOUL.md` in the agent's workspace
  (`~/.pepe/agents/<name>/`); falls back to the config `system_prompt` seed.
- **tools** - the allowlist. A capability = having its tool. Includes built-ins,
  `mcp__<server>__<tool>` MCP tools, and plugin tools.
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
