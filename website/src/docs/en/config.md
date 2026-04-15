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

That prints the config path and a summary of what is defined.

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

<div class="note"><strong>Security-sensitive settings are not editable by the general config tool.</strong> The guarded `config_set` tool is fail-closed: it only touches a short allowlist (the default model and agent, language, timezone, and a couple of Telegram flags). Secrets, tool allowlists, bot tokens, the sandbox wrapper, and the dashboard password are deliberately off that list, so `config_set` cannot change them. You set those yourself with the CLI or the dashboard. API tokens are the one thing an agent can mint by chat, but only through the separate, permission-gated `manage_token` tool, never through `config_set`.</div>
