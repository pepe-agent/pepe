# Self-knowledge & self-management (how an agent operates Pepe)

Pepe is designed so an agent can **resolve requests about Pepe itself** - "add a
bot", "schedule this", "connect Sentry", "switch the timezone" - without bespoke
hand-holding, and without ever being dangerous:

- **It reads its own docs.** How-to guides ship under `priv/docs/` (agents, channels,
  cron, MCP, plugins, permissions, config) and are listed in every agent's system
  prompt as the *authoritative* source; the read-only `docs` tool loads the relevant
  one on demand. New/unforeseen requests get resolved by reading, not guessing.
  (Drop extra guides in `~/.pepe/docs/` to extend or override.)

- **It discovers what's editable.** `config_set` called with no arguments returns the
  schema - the editable settings, their current values and accepted values. The
  editable set is a **fail-closed allowlist** (`default_model`, `default_agent`,
  `language`, `timezone`, `telegram.require_mention/enabled`); anything else is
  refused with a pointer to the right guarded tool (`manage_agent`, `manage_channel`,
  `manage_mcp`, `manage_plugin`, `schedule_task`, `manage_token`). Secrets are never
  editable from chat.

- **It can extend itself with community plugins.** The guarded `manage_plugin` tool
  installs, scans, lists, and removes drop-in `.exs` tools/channels from chat (a
  local path, a `.tar.gz`, or a GitHub URL), through the same `Pepe.Skills.Sentinel`
  static scan the CLI uses. Unlike the CLI's `--force`, this tool has no override: a
  `danger` verdict is always refused from chat - overriding it is an operator
  decision made deliberately at the terminal, never one an agent is talked into
  mid-conversation.

- **It can hand out API access.** The guarded `manage_token` tool mints, lists, and
  revokes `/v1` bearer tokens from chat (scoped to a company or a single agent), so an
  agent can give an integration access without you dropping to a terminal. Like the
  other guarded tools it is not read-only, so it passes the permission gate first.

- **The owner can run the whole CLI.** For an owner-style agent you fully trust,
  `manage_pepe` runs any non-interactive `mix pepe` command from chat (the same
  dispatcher the CLI uses). Interactive and blocking commands (`setup`, `chat`,
  `serve`, foreground gateways) are refused, and it stays behind the permission gate.
  Give it only to a trusted owner agent, never to one exposed to untrusted input.

- **It verifies its own work.** After changing something, the agent (or you) runs the
  **doctor**: offline checks (every `${ENV}` ref resolves, agents point at real
  models and known tools, cron schedules/timezones/agents are valid) plus live probes
  (Telegram `getMe` per bot, a ping per model connection, an MCP launch + tool list
  per server).

```bash
mix pepe doctor              # live probes (Telegram, models, MCP)
mix pepe doctor --offline    # config-consistency only, no network
```

The loop is **do -> verify -> correct**: structured guarded tools for the hot paths,
generic tools + docs for everything else, and the doctor to confirm it worked.

---

[Back to the docs index](../README.md#documentation)
