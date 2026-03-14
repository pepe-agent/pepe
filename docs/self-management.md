# Self-knowledge & self-management (how an agent operates Pepe)

Pepe is designed so an agent can **resolve requests about Pepe itself** - "add a
bot", "schedule this", "connect Sentry", "switch the timezone" - without bespoke
hand-holding, and without ever being dangerous:

- **It reads its own docs.** How-to guides ship under `priv/docs/` (agents, channels,
  cron, MCP, permissions, config) and are listed in every agent's system prompt as
  the *authoritative* source; the read-only `docs` tool loads the relevant one on
  demand. New/unforeseen requests get resolved by reading, not guessing. (Drop extra
  guides in `~/.pepe/docs/` to extend or override.)

- **It discovers what's editable.** `config_set` called with no arguments returns the
  schema - the editable settings, their current values and accepted values. The
  editable set is a **fail-closed allowlist** (`default_model`, `default_agent`,
  `language`, `timezone`, `telegram.require_mention/enabled`); anything else is
  refused with a pointer to the right guarded tool (`manage_agent`, `manage_channel`,
  `manage_mcp`, `schedule_task`). Secrets are never editable from chat.

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
