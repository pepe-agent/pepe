# Configuration (`~/.pepe/config.json`)

```jsonc
{
  "default_model": "openrouter",
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "anthropic/claude-3.5-sonnet",
      "max_tokens": 4096
    }
  },
  "default_agent": "assistant",
  "agents": {
    "assistant": {
      "model": "openrouter",
      "system_prompt": "You are Pepe, a helpful agent.",
      "tools": ["bash", "run_script", "read_file", "write_file", "edit_file", "list_dir", "fetch_url", "web_search"],
      "auto_approve": ["read_file"],
      "max_iterations": 12
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}", "allowed_chats": [], "require_mention": true },
  "locale": "en",
  "server": { "port": 4000 }
}
```

Override the location with `PEPE_HOME` (directory) or `PEPE_CONFIG` (file).
Each agent also gets a persistent directory at `~/.pepe/agents/<name>/` holding
its `SOUL.md` (persona) and any files it creates (`MEMORY.md`, `people.md`, ...);
`~/.pepe/shared/` is shared across agents.

An agent with **no identity yet** (no `SOUL.md`, default seed) presents itself as
Pepe, tells you it has no name or characteristics defined, and offers to set one
up - then saves your choices to `SOUL.md` and renames itself with `rename_agent`.
`auto_approve` lists tools the agent may run without asking (see **Permissions**).

### Storage & backup - it's all files, no database

Everything lives under `~/.pepe/` (or `PEPE_HOME`) - there is **no database
server**. `config.json` is the single source of truth (companies, agents, models,
watches, crons, bots, MCP, hashed API tokens). Agent knowledge lives as files in
`agents/<name>/` and `companies/<co>/agents/<name>/`; conversation history in
`data/sessions/`; `data/mnesia/` is a disposable cache (rebuilds itself). `Pepe.Repo`
+ Postgres exist in the code but are **off** (`ecto_repos: []`) - the door for a future
DB backend, unused today.

Secrets are never stored raw - they're `${ENV_VAR}` references resolved at read time,
so they live in your environment, not the files.

Back up with one command - it archives the durable parts, skips the disposable cache,
and lists the secret env vars you must save separately (they're not in the archive):

```bash
mix pepe backup                       # -> pepe-backup-YYYY-MM-DD.tgz
mix pepe backup --output /path/x.tgz
```

Restore = extract back into `~/` (or `PEPE_HOME`'s parent) and re-export those env
vars. That's the whole disaster-recovery story.

---

[Back to the docs index](../README.md#documentation)
