# Configuration (`~/.pepe/config.json`)

```jsonc
{
  "default_model": "openrouter",
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-5-chat",
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
up, then saves your choices to `SOUL.md` and renames itself with `rename_agent`.
`auto_approve` lists tools the agent may run without asking (see **Permissions**).

### A cheap model for the chores (`utility_model`)

Some model calls are not the agent thinking, they are the agent tidying up. Naming a
conversation so the dashboard sidebar reads like something is the first of them.
Point `utility_model` at any connection you already have and those calls go there:

```jsonc
"assistant": {
  "model": "openrouter",          // does the work
  "utility_model": "groq-fast"    // names the conversation
}
```

```bash
mix pepe agent add assistant --model openrouter --utility-model groq-fast
```

Also on the dashboard (**Agents -> Edit -> Chores**), and by chat, if the agent has
the `manage_agent` tool: *"do your chores on groq-fast"*.

**Leave it unset and conversations are still named**, from the first few words of the
opening message: free, offline, and nobody's first message is sent anywhere to be
read. It is not much worse for what a sidebar is for, which is you recognising the
conversation. What Pepe will never do is fall back to the agent's own model, because
that would start spending on every install that merely upgraded, and Pepe bills those
tokens to a company. A `utility_model` naming a connection that does not exist counts
as unset for the same reason, and `pepe doctor` says so: a typo must not be the thing
that starts spending.

A word of warning about "free" models. The text sent to name a conversation is the
client's **opening message**, which is where the name, the phone number and the
complaint live. Most free tiers pay for themselves with your data. If you would not
put that message in a training set, do not point `utility_model` at one; the no-model
path exists precisely so you do not have to.

Compaction deliberately does **not** use the utility model. A summary written badly
does not merely read badly, it quietly misinforms every turn that reads it afterwards,
and the agent cannot tell. The test is the shape of the failure, not the price: if
being wrong here would only look clumsy, it is a chore; if it would make the agent
wrong, it is not.

### Storage & backup: it's all files, no database

Everything lives under `~/.pepe/` (or `PEPE_HOME`). There is **no database
server**. `config.json` is the single source of truth (companies, agents, models,
watches, crons, bots, MCP, hashed API tokens). Agent knowledge lives as files in
`agents/<name>/` and `companies/<co>/agents/<name>/`; conversation history in
`data/sessions/`; `data/mnesia/` is a disposable cache (rebuilds itself). `Pepe.Repo`
+ Postgres exist in the code but are **off** (`ecto_repos: []`), the door for a future
DB backend, unused today.

Secrets are never stored raw: they're `${ENV_VAR}` references resolved at read time,
so they live in your environment, not the files.

Back up with one command: it archives the durable parts, skips the disposable cache,
and lists the secret env vars you must save separately (they're not in the archive):

```bash
mix pepe backup                       # -> pepe-backup-YYYY-MM-DD.tgz
mix pepe backup --output /path/x.tgz
```

Restore = extract back into `~/` (or `PEPE_HOME`'s parent) and re-export those env
vars. That's the whole disaster-recovery story.

---

[Back to the docs index](../README.md#documentation)
