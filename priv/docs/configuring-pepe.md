# Configuring Pepe - overview

How Pepe is configured, and how you (an agent) can change it safely. Read the
focused docs (`agents`, `channels`, `scheduled-tasks`, `mcp`, `permissions`) for
each area.

## Where config lives

All configuration is a single JSON file at `~/.pepe/config.json` (overridable with
`PEPE_HOME`/`PEPE_CONFIG`). There is **no database**. Top-level keys:

- `models` - model connections (name -> base_url, api_key, model).
- `agents` - agent definitions (name -> prompt, tools, model, routes, admin scope).
- `default_model`, `default_agent` - the defaults.
- `telegram` / `telegrams` - the default Telegram bot + named bots.
- `crons` - scheduled tasks.
- `mcp` - external MCP tool servers.
- `locale`, `timezone` - language + default timezone.

You rarely edit this file directly - prefer the structured tools (below), which
validate and keep it consistent.

## Secrets - never in plaintext

Any secret (API key, bot token, MCP access token) is stored as a **`${ENV_VAR}`
reference**, e.g. `"api_key": "${OPENAI_API_KEY}"`. Pepe interpolates it at read
time; the raw secret lives only in the environment, never in the config file or the
chat. When wiring an integration, always pass the env-var *name*, and ask the user to
set that env var - do not paste the secret.

## The tools you use to configure Pepe

- `docs` - read these docs (you're using it now).
- `config_get` - inspect current settings.
- `config_set` - change a global setting. Call it with **no arguments first**: it
  returns the schema (editable settings, current values, accepted values). Only
  allowlisted settings are editable (fail-closed).
- `doctor` - health-check everything (run it after a change to verify: unset env
  vars, broken agents/crons; `live: true` also probes Telegram/models/MCP).
- `scan_skill` - security-scan skill Markdown before installing it from an external
  source (see the `install-skill` skill). Flags injection/exfiltration/destructive/
  persistence/obfuscation patterns; a `danger` verdict means stop and ask the user.
- `manage_agent` - create/edit agents (persona, model, tools, admin scope) and train
  them. See `agents`.
- `manage_channel` - add/manage Telegram bots. See `channels`.
- `schedule_task` - create recurring tasks. See `scheduled-tasks`.
- `manage_mcp` - connect external MCP tool servers. See `mcp`.
- Generic tools (`bash`, `read_file`, `write_file`, `edit_file`, ...) for anything not
  covered by a structured tool.

## The safe pattern

Do -> verify -> correct. After a change, run `doctor` (or `manage_mcp tools`,
`config_get`) to confirm it worked, and scope access to the minimum needed (e.g.
read-only tools). Risky actions go through a permission gate; that's expected.
