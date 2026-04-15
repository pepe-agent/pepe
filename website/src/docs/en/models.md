---
title: Models
description: Connect OpenAI-compatible model providers and choose defaults and fallbacks.
---

## 3. Connect a model

Point Pepe at any OpenAI-compatible endpoint. Store the key as an environment
reference so the raw secret never lands in the config file.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat \
  --default
```

You will see a confirmation like this:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5-chat)
```

A few things worth knowing:

- Names that match a built-in provider, like `openrouter`, use that provider's
  default endpoint. Use `--base-url` only for custom endpoints.
- Run `pepe model add NAME` with a non-provider name to get a guided picker.
  Choose a provider from the catalog, choose how to authenticate, then choose a
  model from the provider's live list.
- `pepe model providers` lists the providers Pepe knows out of the box.
- `pepe model list` shows every saved connection and marks the default.
- `pepe model test` sends a tiny real request to confirm the connection works.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5-chat)...
✓ openrouter works - reply: pong
```

The dashboard can do all of this too, under its Models tab, if you prefer a form
over the command line.

### Rename a connection

```bash
pepe model rename openrouter OR-work
```

Every agent, cron, and default that points at the connection keeps working -
renaming only changes the display name, not the stable id every reference is
actually stored against, so nothing needs fixing up afterward.

### Switch models mid-conversation

`/model` and `/models` work the same way in Telegram, the console (`pepe chat`),
and the dashboard's own chat - see [Telegram](./telegram/) for the full command
reference. Anyone in an allowed conversation can switch the model for just their
own session; a trainer (the same allowlist that governs `/learn`) can also change
it for everyone.

## The model connection

`model` names a connection you defined with `pepe model add`. Leaving it unset means
the agent uses the default model for its scope, so you can point a whole set of
agents at one provider and switch them all by changing one default.

A model connection can carry a fallback chain. When the agent's primary model fails
with a transient error (a rate limit, a timeout, a network blip, or a 5xx), the
runtime walks down the chain and retries on the next model, emitting a `failover`
event as it does. A hard error like a bad API key or a malformed request fails fast
instead, since another endpoint would not fix it.

Pepe talks to providers over the OpenAI Chat Completions protocol, so any
OpenAI-compatible endpoint works with no code change.

### Do it by chat

An agent with the `manage_agent` tool can repoint a model it administers:

```text
Point the researcher agent at the groq-fast model.
```

The agent calls `manage_agent` with `action: "set_model"`. The target model must be
a configured connection, and the change goes through the permission gate like any
other config edit.
