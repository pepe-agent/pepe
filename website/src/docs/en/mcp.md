---
title: MCP servers
description: Connect Model Context Protocol (MCP) servers, like GitHub or Sentry, and their ready-made tools become usable by your agents as if they were built in.
---

**MCP (Model Context Protocol)** is a standard way for outside services to offer
ready-made tools to AI agents, and many products publish one. Connect an MCP
server, such as Sentry or GitHub, and its tools become callable by your agents
as if they were built in. Tokens go in as `${ENV_VAR}` references.

A server is one of two kinds:

* **Remote**: a URL reached over HTTP. Nothing runs on your machine; you need the
  address and a credential.
* **Local**: a program Pepe launches on demand and talks to directly (through
  `npx`, so there is **nothing to install manually**), running beside Pepe.

## Adding a server

```bash
# remote: a hosted server, reached over HTTP
pepe mcp add memclaw --url https://memclaw.net/mcp \
  --header "Authorization: Bearer ${MEMCLAW_API_KEY}"

# local: a server Pepe launches for itself
pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"

pepe mcp tools sentry     # connect and list its tools (validate the connection)
pepe mcp list
```

`pepe mcp tools` really does start the server and ask it what it can do, so it
doubles as a connection check. A wrong command, a wrong argument or a bad token
shows up there, instead of in the middle of a conversation.

Server definitions live in `~/.pepe/config.json` under `"mcp"`.

## Remote servers: the transport picks itself

There are two ways a remote MCP server can talk, and they are told apart only by
trying: **Streamable HTTP**, which is what a server published today speaks, and the
older **HTTP+SSE** pair, which some have not migrated from. Pepe tries the newer one
and falls back, so you give it a URL and nothing else.

Pin it with `--transport streamable` or `--transport sse` only if the negotiation gets
it wrong. Guessing wrong looks exactly like a broken URL, which is why the fallback is
the default rather than a flag you have to know about.

## Signing in to a server that wants OAuth

Some hosted servers take no API key at all and answer `401` until you sign in:

```bash
pepe mcp login memclaw
```

Pepe asks the server where its authorization server is, registers itself as a client
there, opens your browser, and stores the resulting grant. Nothing has to be filled in
by hand - not a client id, not an endpoint - because the whole point of the discovery
step is that you were never told any of it. Over SSH, where there is no browser to
open, it prints the link and takes the pasted code instead.

The grant is refreshed automatically when it expires. `pepe mcp logout NAME` forgets it.
The dashboard's MCP page does the same sign-in with a button, and shows which servers
are signed in.

<div class="note"><strong>Tokens are not in <code>config.json</code>.</strong> A static key you configure yourself lives in the environment and is referenced as <code>${VAR}</code>. An OAuth grant cannot work that way - it rotates on its own - so it is stored in Pepe's local database instead, and never written to the config file.</div>

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
