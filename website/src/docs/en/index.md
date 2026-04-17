---
title: Introduction
description: Pepe is a self-hosted, model-agnostic AI agent runtime. Define agents, connect any OpenAI-compatible model, and run a real tool-calling loop, with no database and no vendor lock-in.
---

## What Pepe is

Pepe is a self-hosted AI agent runtime built in Elixir. You define an **agent**
(a name, a system prompt, a set of tools, and a model connection), and Pepe runs
it: it sends the conversation to the model, executes any tools the model asks
for, feeds the results back, and repeats until the model produces a final answer.

Elixir/OTP matters here because agents are long-lived conversations, channels and
background jobs, not just one HTTP request. Pepe can keep many supervised sessions
running with low runtime overhead, which helps keep a team of agents inexpensive
to host in terms of server memory and CPU.

That inner loop is the whole point. A plain chat call returns text. An agent can
actually do things: read a file, run a command, search the web, call your API,
and then reason about what it found and keep going. Pepe gives you that loop as a
finished runtime instead of something you wire up by hand for every project.

```bash
pepe run "read package.json and tell me which dependencies are outdated"
```

You define the behavior once, and the same agent is reachable four ways: from the
terminal, over an OpenAI-compatible HTTP API, over a streaming WebSocket, and
from messaging channels like Telegram and WhatsApp. There is also a web dashboard
for browsing and chatting from the browser. Meet each use case where it already
lives, without creating a separate agent for each channel.

## The tool-calling loop

Here is the cycle Pepe runs for every turn:

1. Send the conversation, plus the agent's tool definitions, to the model.
2. If the model returns tool calls, run each tool and collect its output.
3. Append the assistant message and the tool results to the conversation.
4. Go back to step 1. Stop when the model returns a plain answer, or when the
   agent hits its `max_iterations` safety limit.

Along the way the runtime emits lifecycle events so any surface can show progress
in real time: streamed text fragments (`assistant_delta`), a full assistant turn
(`assistant`), each tool call (`tool_call`), each tool result (`tool_result`),
the final answer (`done`), and errors (`error`). Streaming surfaces render tokens
as they arrive.

Risky tools (anything that runs a command or writes a file) can be sent through a
permission gate that asks the user to approve before the tool runs. If the user
refuses, the runtime emits a `tool_denied` event and hands the model a short
"denied" message instead of running the tool, so an agent never silently acts on
your machine without consent.

<div class="note"><strong>Built-in tools.</strong> Every agent can be given tools like <code>bash</code>, <code>read_file</code>, <code>write_file</code>, <code>edit_file</code>, <code>list_dir</code>, <code>fetch_url</code>, and <code>web_search</code>. You choose which ones each agent gets when you create it, so a support bot and a coding agent can have very different powers.</div>

## The four surfaces

You build an agent once. Pepe then exposes it through whichever surface fits the
job. Setup and management themselves happen three ways: the `pepe` CLI, the web
dashboard, and by chat (talking in plain language to an agent that holds the
matching management tool).

### CLI

The `pepe` command is how you set things up and how you run agents from a
terminal. One-shot runs stream their answer straight to stdout, and `pepe chat`
opens an interactive session that remembers the conversation.

```bash
pepe run assistant "summarize the git log from the last week"
pepe chat assistant
```

### Web dashboard

Run the server and open the dashboard in a browser to chat with an agent, browse
past sessions, and manage agents, model connections, channels, scheduled tasks,
usage, and traces from a point-and-click UI. On localhost it is open by default;
you can gate it behind an operator password when you expose it.

```bash
pepe serve --port 4000
# then open http://localhost:4000
```

### OpenAI-compatible HTTP API

Start the server and Pepe speaks the OpenAI Chat Completions protocol, so any
OpenAI SDK, LangChain, or a plain `curl` can talk to it with no adapter. It
serves `POST /v1/chat/completions` and `GET /v1/models`.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role": "user", "content": "what files are in this project?"}]
  }'
```

Point an existing OpenAI client at `http://localhost:4000/v1` and the model name
becomes your agent name. See [the HTTP API page](../api/) for streaming, tool
events, and authentication.

### WebSocket

For live, token-by-token conversations in a web or mobile app, connect over a
WebSocket and subscribe to the topic for your agent (`agent:<name>`). You receive
assistant text as it streams, plus events for each tool call and result. Details
and a client example are on [the API page](../api/).

### Messaging channels

Put the same agent in front of real users on the platforms they already use.
Pepe ships gateways for Telegram, WhatsApp, Slack, Discord, Microsoft Teams, and
Google Chat, plus a generic inbound webhook for anything else. Each channel binds
to an agent and keeps its own conversation memory per user. See
[the channels page](../channels/).

## Defining an agent

An agent is just a name, a system prompt, a tool list, and a model. Create one
from the CLI:

```bash
pepe agent add assistant \
  --prompt "You are Pepe, a helpful coding agent." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

You can also do this in the web dashboard on the **Agents** page, which includes
a form for the persona, model, and tool selection.

### Do it by chat

An agent that holds the `manage_agent` tool can create and shape other agents
straight from a conversation. Send it a plain message:

> You: Create a new agent called "researcher" whose job is to dig through docs
> and summarize findings, and give it web_search and fetch_url.

The agent uses `manage_agent` to `create` the new agent, set its persona, and add
each tool. `manage_agent` is a guarded capability: the agent may only touch
agents on its own allowlist, it is instructed to confirm the changes with you
first, and because it is a risky tool each call still passes through the
permission gate before anything is written. So you see the proposed change and
approve it before it takes effect.

## Connecting a model

Pepe never ships a model or a key. You point it at any OpenAI-compatible provider
with a model connection:

```bash
pepe model add openrouter \
  --api-key '${OPENROUTER_API_KEY}' \
  --model anthropic/claude-3.5-sonnet \
  --default
```

The **Models** page in the dashboard does the same thing with a form, and can
test a connection before you save it. Notice the `${OPENROUTER_API_KEY}`: secrets
are stored as environment-variable references and expanded only when read, so
your keys are never written back to disk in plain text.

## Adding a channel

Bind an agent to a messaging channel so people can talk to it where they already
are. From the dashboard, the **Channels** page walks you through connecting a bot
and choosing which agent it talks to. The channel then keeps a separate
conversation memory per user.

### Do it by chat

An agent that holds the `manage_channel` tool can stand up a Telegram bot from a
conversation:

> You: Add a Telegram bot named "support-bot" that talks to the support agent.
> The token is in the env var SUPPORT_BOT_TOKEN.

The agent uses `manage_channel` to add the bot and bind it to the named agent.
This capability is deliberately guarded: it only touches named bots (never the
protected default), it is instructed to confirm the details with you first, and
it is a risky tool, so the call goes through the permission gate. Crucially, you
give the **name** of an environment variable that holds the token, never the
token itself, so the secret never passes through the chat or the model. After the
change the running bot starts live, with no restart.

## Design choices that keep it simple

### Self-hosted, your keys, your data

Pepe never ships a model or an API key. You run it on your own machine or server,
and you point it at whatever provider you want. Nothing about a conversation
leaves your infrastructure except the calls you configure to your chosen model
endpoint.

### Model-agnostic

Because every provider is reached over the same OpenAI Chat Completions protocol,
switching models is a config change, not a code change. OpenAI, OpenRouter,
Together, Groq, DeepSeek, Mistral, and local servers like Ollama, LM Studio, and
vLLM all work the same way. A model connection can even list fallback models, so
a transient failure (a rate limit, a server error, a network blip) on one
provider quietly rolls over to the next, while a bad key or a malformed request
fails fast instead of retrying pointlessly.

### No database

All configuration (model connections, agents, channels, schedules) lives in a
single JSON file at `~/.pepe/config.json`. There is nothing to provision and
nothing to migrate. Secrets are written as `${ENV_VAR}` references and expanded
only when read, so your keys are never written back to disk in plain text.

```json
{
  "models": {
    "openrouter": {
      "base_url": "https://openrouter.ai/api/v1",
      "api_key": "${OPENROUTER_API_KEY}",
      "model": "anthropic/claude-3.5-sonnet"
    }
  }
}
```

### Isolated conversations

Each conversation runs as its own lightweight, supervised process keyed by a
session id. Many run side by side, and a crash in one never touches another, so a
single bad turn cannot take down the rest of your agents.

### Multi-tenant when you need it

Work can be scoped to a **company**, isolating agents, channels, models, and
usage per tenant. If you never opt in, everything lives in the default scope,
called **Principal**, and you can ignore companies entirely.

## Where to go next

- [Quickstart](../quickstart/). Install Pepe, connect a model, and run your first
  agent in a few minutes.
- [Agents and tools](../agents/). What an agent is made of and how it decides to
  use tools.
- [HTTP API](../api/). Drive Pepe from any OpenAI-compatible client, over both the
  request/response and streaming paths.
- [Channels](../channels/). Put an agent on Telegram, WhatsApp, Slack, and more.
- [Scheduled tasks](../scheduled/). Run agents on a recurring schedule.
- [Security and permissions](../security/). The permission gate, sandboxing, and
  how to keep an agent inside safe boundaries.
