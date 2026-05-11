---
title: Manage by chat
description: Let trusted agents configure Pepe from natural-language conversations.
---

Trusted agents can manage Pepe from a conversation when you grant the matching management tools. These actions are guarded because they change runtime state or expose access.

Pepe is built so that an agent can resolve a request about Pepe itself, such as "add a bot", "schedule this", "connect Sentry", or "switch the timezone", without bespoke hand-holding for every case and without ever being dangerous. It gets there by reading its own documentation, by discovering what it is allowed to change, by using a small set of guarded tools for the common paths, and by verifying its own work afterwards.

## It reads its own docs

The how-to guides ship with Pepe, under `priv/docs/`, and cover agents, channels, cron, MCP, plugins, permissions and config. Every agent's system prompt lists them as the authoritative source, and the read-only `docs` tool loads the relevant one on demand. A new or unforeseen request gets resolved by reading, not by guessing. Drop extra guides in `~/.pepe/docs/` to extend or override the ones that ship.

## It discovers what is editable

Call `config_set` with no arguments and it returns its own schema: the settings it may edit, their current values, and the values they accept. The editable set is a fail-closed allowlist, namely `default_model`, `default_agent`, `language`, `timezone`, and `telegram.require_mention` / `telegram.enabled`. Anything else is refused, with a pointer to the right guarded tool for the job: `manage_agent`, `manage_channel`, `manage_mcp`, `manage_plugin`, `schedule_task`, or `manage_token`. Secrets are never editable from chat.

## Administering agents

`can_manage` controls which agents an agent may administer (create, edit,
reconfigure, train) through the `manage_agent` tool. It is closed by default and its
meaning is precise:

- Unset (`null`): the agent may manage only itself.
- Empty (`[]`, set with `--can-manage none`): it may manage nobody, not even itself.
  A locked child, for example a client-facing agent that must not alter itself.
- A list of names: exactly those agents, and no others. Include its own name to let
  it manage itself too.
- `["*"]` (set with `--can-manage "*"`): every agent. An explicit super-admin.

Grant management authority directly:

```bash
pepe agent manage supervisor "*"
```

### Do it by chat

An admin agent uses `manage_agent` to shape the agents in its scope. Its actions are
`list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`, `remove_tool`, and
`remember` (append a durable fact to the target's memory). For example:

```text
Give the support agent the send_file tool and add a note to its memory that
refunds over 200 need a human.
```

The agent calls `manage_agent` with `action: "add_tool"` and then
`action: "remember"`. Every one of these actions is gated: the agent proposes the
change, you authorize it, and only then is it applied. An agent can also rename
itself with the separate `rename_agent` tool ("From now on, call yourself scout"),
which moves its workspace directory and takes effect on the next message.

## Installing community plugins

The guarded `manage_plugin` tool installs, scans, lists, and removes drop-in `.exs` tools and channels from chat. It takes a local path, a `.tar.gz`, or a GitHub URL, and every install goes through the same static scan the CLI uses.

Unlike the CLI, this tool has no `--force`. A `danger` verdict from the scan is always refused from chat. Overriding a dangerous verdict is an operator decision, made deliberately at the terminal, and never one an agent can be talked into mid-conversation.

## Handing out API access

The guarded `manage_token` tool mints, lists, and revokes `/v1` bearer tokens from chat, scoped to a company or to a single agent. An agent can therefore give an integration access without you dropping to a terminal. Like the other management tools it is not read-only, so it passes the permission gate first.

## The owner can run the whole CLI

For an owner-style agent you fully trust, `manage_pepe` runs any non-interactive `pepe` command from chat, through the same dispatcher the CLI uses. Interactive and blocking commands (`setup`, `chat`, `serve`, and foreground gateways) are refused, and it stays behind the permission gate. Give it only to a trusted owner agent, never to one exposed to untrusted input. See [Security and sandbox](../security/) for the details.

## It verifies its own work

After changing something, the agent (or you) runs the doctor. It performs offline checks, confirming that every `${ENV}` reference resolves, that agents point at real models and known tools, and that cron schedules, timezones and agents are valid. It also runs live probes: a Telegram `getMe` per bot, a ping per model connection, and an MCP launch plus tool listing per server.

```bash
pepe doctor              # live probes (Telegram, models, MCP)
pepe doctor --offline    # config consistency only, no network
```

The loop is do, then verify, then correct: structured guarded tools for the common paths, generic tools plus the docs for everything else, and the doctor to confirm it worked.
