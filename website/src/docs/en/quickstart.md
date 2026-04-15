---
title: Quickstart
description: Install Pepe, create an agent, and run the first conversation.
---

In a few commands you install Pepe, create an agent, and talk to it. `pepe setup`
takes the shortest path: model, key, first agent, and optional channel setup.

## 1. Install

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
pepe help
```

## 2. Configure

```bash
pepe setup
```

The guided setup writes `~/.pepe/config.json`. When it asks for a key, prefer a
reference like `${OPENROUTER_API_KEY}` so the secret stays out of the file.

## 3. Talk

```bash
pepe run assistant "what files are in this directory?"
```

If you set a default agent, omit the name:

```bash
pepe run "summarize the README in three bullets"
```

For an ongoing conversation:

```bash
pepe chat assistant
```

`pepe run` is a one-shot and does not keep context. To resume a terminal
conversation, use a console session:

```bash
pepe chat assistant --session my-session
```

When a tool wants to act on your machine, such as running shell or writing a file,
Pepe asks for approval first.

## 4. Serve the API and dashboard

```bash
pepe serve --port 4000
```

This exposes the same agent in three places:

- Local dashboard: `http://localhost:4000`
- OpenAI-compatible API: `POST /v1/chat/completions`
- WebSocket: `ws://localhost:4000/socket/websocket`

Test the API:

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hi"}]}'
```

<div class="note"><strong>The API starts local.</strong> With no tokens, only same-machine callers can access <code>/v1</code>. Create a token with <code>pepe token add</code> before exposing the server.</div>

## 5. Connect a channel

Telegram is the fastest test because it does not require a public URL:

```bash
pepe gateway telegram setup
pepe gateway telegram
```

After that, anyone messaging the bot talks to the same agent. WhatsApp, Slack,
Discord, Teams, and Google Chat are covered in [Channels](./channels/).

## 6. Automate

```bash
pepe cron add
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
```

Use scheduled tasks for recurring routines and watches for one-shot notifications
when a condition changes.

## Next steps

- [Agents and tools](./agents/)
- [HTTP API](./api/)
- [Channels](./channels/)
- [Scheduled tasks](./scheduled/)
- [Security and permissions](./security/)
- [Plugins](./plugins/)
