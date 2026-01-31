# Agents — create, edit, train

An agent is a persona (system prompt) + a model + an allowlist of tools + loop
limits. You manage other agents with the `manage_agent` tool (only agents within your
admin scope — see below).

## Anatomy

- **name**, **model** (a configured connection; blank = default model).
- **persona** — the system prompt. Stored as `SOUL.md` in the agent's workspace
  (`~/.cortex/agents/<name>/`); falls back to the config `system_prompt` seed.
- **tools** — the allowlist. A capability = having its tool. Includes built-ins,
  `mcp__<server>__<tool>` MCP tools, and plugin tools.
- **can_message** — directed routing: which agents it may message.
- **can_manage** — admin scope: which agents it may administer (see below).
- **memory** — `MEMORY.md` / `USER.md` in its workspace.

## Managing an agent (`manage_agent`)

- `list` — agents you may manage.
- `get target: X` — X's definition.
- `create target: X [value: persona]` — a new agent.
- `set_persona target: X value: "..."` — set X's persona (SOUL.md).
- `set_model target: X value: <model>`.
- `add_tool` / `remove_tool target: X value: <tool>` — grant/revoke one tool.
- `remember target: X value: "..."` — append a durable fact to X's memory (train it).

## Admin scope (`can_manage`) — who can configure whom

- **omitted / null** → the agent may manage only itself.
- **`[]`** → nobody, not even itself (a locked agent, e.g. client-facing).
- **`["a", "b"]`** → exactly those agents (add its own name to include itself).
- **`["*"]`** → every agent (an explicit super-admin).

An agent can only `manage_agent` a target inside its `can_manage`. Authority defaults
to closed. Grant it deliberately (CLI: `mix cortex agent manage ADMIN TARGET`).
