---
title: Configuration
description: Understand where Pepe stores configuration, secrets, and runtime state.
---

## Where your setup lives

Everything you did above is now in `~/.pepe/config.json`: the model connection,
the agent, and any channels. No database, no migrations. To move a setup to
another machine, copy that file and set the same environment variables your
`${VAR}` references point to.

```bash
pepe config
```

That prints the config path and a summary of what is defined. A complete file looks like this:

```json
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

`auto_approve` lists the tools that agent may run without stopping to ask you, as covered on the Security page. Override where the file lives with `PEPE_HOME` (a directory) or `PEPE_CONFIG` (a file).

### What an agent keeps on disk

Each agent also gets a persistent directory at `~/.pepe/agents/<name>/`. It holds the agent's `SOUL.md` (its persona) and any files it creates as it works (`MEMORY.md`, `people.md`, and whatever else it decides to keep). `~/.pepe/shared/` is shared across every agent.

An agent with no identity yet (no `SOUL.md`, still on the default seed) presents itself as Pepe, tells you it has no name or characteristics defined, and offers to set one up. It then saves your choices to `SOUL.md` and renames itself with the `rename_agent` tool.

### A cheap model for the chores (`utility_model`)

Some model calls are not the agent thinking, they are the agent tidying up. Naming a conversation, so the dashboard sidebar reads like something, is the first of them. Point `utility_model` at any connection you already have and those calls go there:

```json
{
  "agents": {
    "assistant": {
      "model": "openrouter",
      "utility_model": "groq-fast"
    }
  }
}
```

`model` does the work and `utility_model` names the conversation. The same thing from the CLI:

```bash
pepe agent add assistant --model openrouter --utility-model groq-fast
```

It is also on the dashboard, under Agents, then Edit, then Chores. An agent that has the `manage_agent` tool can do it by chat: "do your chores on groq-fast".

**Leave it unset and conversations are still named**, from the first few words of the opening message. That is free, it is offline, and nobody's first message is sent anywhere to be read. It is not much worse for what a sidebar is actually for, which is you recognising the conversation. What Pepe will never do is fall back to the agent's own model, because that would start spending on every install that merely upgraded, and Pepe bills those tokens to a project. A `utility_model` naming a connection that does not exist counts as unset for the same reason, and `pepe doctor` says so: a typo must not be the thing that starts spending.

A word of warning about "free" model tiers. The text sent to name a conversation is the client's **opening message**, which is where the name, the phone number, and the complaint live. Most free tiers pay for themselves with your data. If you would not put that message in a training set, do not point `utility_model` at one. The no-model path exists precisely so you do not have to.

Compaction deliberately does not use the utility model. A summary written badly does not merely read badly, it quietly misinforms every turn that reads it afterwards, and the agent cannot tell. The test is the shape of the failure, not the price: if being wrong would only look clumsy, it is a chore; if it would make the agent wrong, it is not.

## Secrets stay as references

Configuration lives in a plain JSON file at `~/.pepe/config.json`. There is no database. To keep credentials out of that file, write them as `${ENV_VAR}` references. Pepe interpolates them against the environment at read time and never persists the expanded value.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "openai/gpt-4o-mini"
    }
  },
  "telegram": { "bot_token": "${TELEGRAM_BOT_TOKEN}" }
}
```

At runtime the real key is read from the environment. On disk the file only ever contains the placeholder. The same mechanism works for gateway tokens, plugin settings, and the dashboard password, so you can commit or share a config without leaking anything. Export the variables before you serve:

```bash
export OPENROUTER_API_KEY=sk-...
export TELEGRAM_BOT_TOKEN=123456:AA...
pepe serve --port 4000
```

A whole-string placeholder that resolves to nothing (the variable is unset) is treated as "unset" rather than an empty string, so a missing secret surfaces as a clear "not configured" rather than a silent blank.

### Do it by chat

An agent granted the read-only `config_get` and `doctor` tools can report on your setup and catch a missing secret in plain conversation. Both are read-only, so they never trigger the permission gate.

> You: Is everything configured correctly?
>
> Agent: (runs `doctor`) I found one problem: the model connection "openrouter" references `${OPENROUTER_API_KEY}`, but that variable is not set in the environment. Export it before serving.

The `doctor` tool health-checks the whole setup and flags unset `${ENV}` secrets, agents pointing at missing models, invalid schedules, and unreachable connections. Pass `live: true` to also probe the network.

<div class="note"><strong>Security-sensitive settings are not editable by the general config tool.</strong> The guarded `config_set` tool is fail-closed: it only touches a short allowlist (the default model and agent, language, timezone, a couple of Telegram flags, and `secrets.expose_env` — the list of env-var *names* the agent's shell keeps past the scrub, so it can open a vault it holds a token for). Secret *values*, tool allowlists, bot tokens, the sandbox wrapper, and the dashboard password are deliberately off that list, so `config_set` cannot change them. You set those yourself with the CLI or the dashboard. API tokens are the one thing an agent can mint by chat, but only through the separate, permission-gated `manage_token` tool, never through `config_set`.</div>

## Storage and backup: it is all files, no database

Everything lives under `~/.pepe/` (or `PEPE_HOME`). There is no database server. `config.json` is the single source of truth for projects, agents, models, watches, crons, bots, MCP servers, and hashed API tokens. Projects and agents are keyed by a stable internal id, so renaming one just relabels it and moves its directory while every id-based reference keeps pointing at it. An agent's knowledge lives as files in `projects/<slug>/agents/<name>/` (the default project included, under its own slug), conversation history in `data/sessions/`, and `data/mnesia/` is a disposable cache that rebuilds itself. `Pepe.Repo` and Postgres exist in the code but are switched off (`ecto_repos: []`); they are the door left open for a future database backend, unused today.

Secrets are never stored raw. They are `${ENV_VAR}` references resolved at read time, so they live in your environment rather than in the files.

Back up with one command. It archives the durable parts, skips the disposable cache, and lists the secret environment variables you have to save separately, because they are deliberately not in the archive:

```bash
pepe backup                       # writes pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /path/x.tgz
```

To restore, `pepe restore that-archive.tgz` and export those variables again. You can also lift a single project out to run on its own server with `pepe extract`. See [Backup & extract](/en/docs/backup/) for the whole story.
