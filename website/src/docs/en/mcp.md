---
title: MCP servers
description: Connect Model Context Protocol servers so their tools become callable by your agents.
---

Connect **MCP (Model Context Protocol)** servers, such as Sentry or GitHub, and
their tools become callable by agents as if they were built in. Servers launch
over stdio on demand (through `npx`, so there is **nothing to install
manually**), and tokens go in as `${ENV_VAR}` references.

## Adding a server

```bash
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"
pepe mcp tools sentry     # launch it and list its tools (validate the connection)
pepe mcp list
```

`pepe mcp tools` really does start the server and ask it what it can do, so it
doubles as a connection check. A wrong command, a wrong argument or a bad token
shows up there, instead of in the middle of a conversation.

Server definitions live in `~/.pepe/config.json` under `"mcp"`.

## How the tools are named

Each MCP tool is exposed to agents as `mcp__<server>__<tool>`. The server name
you chose when adding it is the middle segment, so the same tool from two
different servers never collides.

## Scoping is just the tool allowlist

There is no second permission model for MCP. **Scoping is the agent's tool
allowlist.** To make an agent *read-only* against a server, give it only the read
tools and leave the mutating ones out:

```bash
pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (no mcp__sentry__update_issue, so the agent can look, not change)
```

The wildcard `mcp__sentry__*` grants all of that server's tools at once.

MCP tools are risky, so each call still goes through the permission gate. The
allowlist decides what an agent is allowed to reach for; the gate decides whether
this particular call goes ahead.

## Managing servers from chat

An agent holding the `manage_mcp` tool can add and validate servers itself, from
a conversation. Secrets stay as `${ENV}` references on that path too, so nothing
is ever written to disk expanded.

## If a token gets pasted in the clear

Pepe used to refuse to save a server when it spotted a raw-looking token. That
felt responsible and did nothing, because of *when* it happened: by then the
token had been typed into a chat, so it had already gone to the model provider
and was already sitting in the conversation and in the trace on disk. The refusal
did not un-leak it. All it accomplished was that the server did not get added and
the person did not know why.

So the server is saved, and the answer tells the truth: **that token is
compromised, revoke and reissue it**, put the new one in an environment variable,
and refer to it as `${...}`. `pepe doctor` keeps saying so, for anyone who did
not read it the first time. It now also finds a token filed under any
credential-shaped name (`GITHUB_TOKEN`, `BRAVE_API_KEY`), which the old check,
matching a fixed list of exact key names, walked straight past.

<div class="note"><strong>Secrets stay as references.</strong> Write a token as <code>${SENTRY_AUTH_TOKEN}</code> and Pepe interpolates it at read time, never persisting it expanded. The value lives in the environment; <code>~/.pepe/config.json</code> only holds the reference.</div>
