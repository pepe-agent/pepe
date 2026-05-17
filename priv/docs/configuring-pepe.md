# Configuring Pepe - overview

How Pepe is configured, and how you (an agent) can change it safely. Read the
focused docs (`agents`, `channels`, `scheduled-tasks`, `mcp`, `plugins`,
`permissions`) for each area.

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

## What the file looks like

A small, realistic `~/.pepe/config.json` (secrets are `${ENV}` refs, never raw):

```jsonc
{
  "default_model": "gpt",
  "models": {
    "gpt": { "base_url": "https://api.openai.com/v1", "api_key": "${OPENAI_API_KEY}", "model": "gpt-4o" }
  },
  "default_agent": "assistant",
  "agents": {
    "assistant": {
      "model": "gpt",
      "system_prompt": "You are a helpful assistant.",
      "tools": ["bash", "read_file", "write_file", "web_search"],
      "can_message": [],
      "can_manage": null
    }
  },
  "companies": { "acme": { "description": "Acme Inc", "default_model": "gpt" } },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [] },
  "server": { "port": 4000 },
  "timezone": "America/Sao_Paulo"
}
```

An agent references a model by name (`"model": "gpt"`); `can_message` is its routing
allowlist and `can_manage` its admin scope (`null` = itself only - see `permissions`).
Keys you don't use are simply absent.

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
- `manage_plugin` - install/scan/remove community plugins (tools, channels). See `plugins`.
- Generic tools (`bash`, `read_file`, `write_file`, `edit_file`, ...) for anything not
  covered by a structured tool.

## Your workspace on disk

Beyond `config.json`, each agent has a private, persistent **workspace** directory -
`~/.pepe/agents/<name>/` for a root agent, `~/.pepe/companies/<co>/agents/<name>/` for
a company one. Relative paths in your file tools land there and survive across
conversations. A cross-agent `~/.pepe/shared/` (per-company under
`companies/<co>/shared/`) is reachable via a `shared/...` path.

A few filenames are **conventions** you may create and maintain yourself:

- `SOUL.md` - your persona. It (or the config `system_prompt` seed) is what defines
  who you are; small and loaded straight into the system prompt at session start.
- `IDENTITY.md`, `BOOT.md` - also small and loaded at session start (`BOOT.md` is
  re-read fresh each new conversation - write things to pick up next time there).
- `MEMORY.md`, `AGENTS.md`, `USER.md`, `people.md` - larger knowledge files that are
  only **listed by name**, not preloaded, so a growing `MEMORY.md` never bloats your
  context. Read them on demand with `read_file`, append to them with `write_file` /
  `edit_file` as you learn.

This is autonomy by convention, not hardcoded code: ordinary file tools plus a place
where files persist. Rename yourself with `rename_agent` (it moves this directory too).

## Backup, extract, and restore

`mix pepe backup` tars the durable parts of `~/.pepe` - `config.json`, every agent and
company workspace, `shared`, and sessions - into a `.tgz`, skipping the disposable
Mnesia cache (it rebuilds itself). Optional `--output FILE.tgz` picks the path.

```bash
mix pepe backup                          # writes pepe-backup-YYYY-MM-DD.tgz
mix pepe backup --output ~/pepe-safe.tgz
```

`mix pepe extract COMPANY` lifts one company out as a **standalone, root-scoped**
archive: its `company/agent` handles are rewritten to bare names, so the `.tgz` is a
fresh single-tenant install that is only that company - drop it on a new server and run.
Only that company's agents, models, workspaces and usage travel, plus any shared model
its agents depend on (the command names them). Nothing of the other tenants goes with it.

```bash
mix pepe extract acme                    # writes acme-extract-YYYY-MM-DD.tgz
mix pepe extract acme --output ~/acme.tgz
```

`mix pepe restore FILE.tgz` unpacks either archive (a backup or an extract - same shape)
into `~/.pepe`. It **replaces** what is there, so it refuses a non-empty home unless you
pass `--force`.

```bash
mix pepe restore ~/acme.tgz              # into a fresh ~/.pepe
mix pepe restore ~/pepe-safe.tgz --force # over an existing one
```

Because every secret is a `${ENV_VAR}` reference, **no secret is in any of these
archives** - each command prints the env-var names it found (and whether each is
currently set) so you re-provision them on the destination.

## The safe pattern

Do -> verify -> correct. After a change, run `doctor` (or `manage_mcp tools`,
`config_get`) to confirm it worked, and scope access to the minimum needed (e.g.
read-only tools). Risky actions go through a permission gate; that's expected.
