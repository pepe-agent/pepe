---
title: Quickstart
description: Install Pepe, connect a model, define an agent, and talk to it, then expose that same agent over HTTP, a WebSocket, and a chat channel, in a few minutes.
---

Pepe is a self-hosted AI agent runtime. You define an agent (a name, a system
prompt, a set of tools, and a model connection) and Pepe runs the tool-calling
loop for you. It calls the model, runs any tools the model asked for, feeds the
results back, and repeats until the model produces a final answer.

Pepe talks to any OpenAI-compatible provider over the Chat Completions protocol,
so OpenAI, OpenRouter, Together, Groq, DeepSeek, Mistral, a local Ollama, and
anything else that speaks the same API all work with no code change. Pepe is
built in Elixir, but you do not need to know Elixir to use it. This page takes
you from nothing to a talking agent, then puts that same agent behind an HTTP
API, a WebSocket, and a chat channel.

There are three ways to drive Pepe, and most of what follows can be done in any
of them:

1. The `pepe` command-line tool.
2. The web dashboard that ships with the server.
3. By chat, talking in plain language to an agent that holds the relevant
   management tool.

Where a step can be done by chat, you will find a short "Do it by chat"
subsection showing the message you would send and what the agent does.

## 1. Install

One command installs the `pepe` binary.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Check it landed:

```bash
pepe help
```

Everything Pepe knows lives in a single JSON file at `~/.pepe/config.json`.
There is no database to run. You can edit that file by hand later, but the
commands below write it for you.

## 2. Guided setup (the fast path)

`pepe setup` walks you through the whole thing. It picks a provider, signs in or
takes an API key, picks a model, creates your first agent, and offers to wire up
a chat channel and the dashboard.

```bash
pepe setup
```

If you would rather do each step explicitly, skip setup and follow steps 3 to 6.
The two paths write the same config, so you can mix them freely.

<div class="note"><strong>Secrets stay out of the file.</strong> When Pepe asks for an API key it accepts a <code>${ENV_VAR}</code> reference, for example <code>${OPENROUTER_API_KEY}</code>. The reference is what gets written to <code>~/.pepe/config.json</code>. The real value is read from your environment at run time and is never stored expanded.</div>

## 3. Connect a model

Point Pepe at any OpenAI-compatible endpoint. Store the key as an environment
reference so the raw secret never lands in the config file.

```bash
export OPENROUTER_API_KEY=sk-...

pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5 \
  --default
```

You will see a confirmation like this:

```bash
✓ model connection openrouter saved -> https://openrouter.ai/api/v1 (openai/gpt-5)
```

A few things worth knowing:

- Run `pepe model add NAME` with no `--base-url` to get a guided picker. Choose a
  provider from the catalog, choose how to authenticate, then choose a model from
  the provider's live list.
- `pepe model providers` lists the providers Pepe knows out of the box.
- `pepe model list` shows every saved connection and marks the default.
- `pepe model test` sends a tiny real request to confirm the connection works.

```bash
pepe model test openrouter
```

```bash
pinging openrouter (openai/gpt-5)...
✓ openrouter works - reply: pong
```

The dashboard can do all of this too, under its Models tab, if you prefer a form
over the command line.

## 4. Add an agent

An agent is a name, a system prompt, and an allowlist of tools it may use. If you
leave `--tools` off, the agent gets every built-in tool. Pass a comma-separated
list to narrow it down. Add `--model` to bind a specific model connection, or
omit it to use your default.

```bash
pepe agent add assistant \
  --prompt "You are a helpful, concise assistant." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search \
  --default
```

```bash
✓ agent assistant saved (tools: bash, read_file, write_file, edit_file, list_dir, fetch_url, web_search)
```

The built-in tools cover the common ground: shell commands (`bash`,
`run_script`), files (`read_file`, `write_file`, `edit_file`, `move_file`,
`list_dir`), and the web (`fetch_url`, `web_search`), plus a set of management
tools covered later on this page. See the full list any time with:

```bash
pepe tools
```

<div class="note"><strong>Tools are how you grant capability.</strong> An agent can only do what its tools allow. Give a support agent <code>fetch_url</code> and <code>web_search</code> but no <code>bash</code>, and it simply cannot run shell commands. Start narrow and add tools as you trust the agent.</div>

The dashboard has an Agents tab that does the same thing with a form.

### Do it by chat

An agent that holds the `manage_agent` tool can create and shape other agents in
conversation. Two things gate it: the tool must be in the acting agent's
allowlist, and the acting agent must have authority over the target (granted with
`pepe agent manage ADMIN TARGET`, or `"*"` for all). Because it is a risky tool,
each change also passes through the permission gate, where you approve it before
it is applied.

You would send:

> Create an agent called researcher that digs up sources and summarizes them.
> Give it web_search and fetch_url, nothing else.

The agent confirms the details with you, then (on your approval at the permission
prompt) creates the `researcher` agent, sets its persona, and grants the two
tools. The same tool can also point an agent at a different model, add or remove a
single tool, and append durable facts to an agent's memory.

## 5. Talk to it

Run a single prompt. The answer streams to your terminal as the model produces
it, and any tool calls run along the way.

```bash
pepe run assistant "what files are in this directory?"
```

Drop the agent name to use your default agent:

```bash
pepe run "summarize the README in three bullets"
```

For a back-and-forth conversation that remembers context, open the interactive
console. It keeps the session so follow-up questions build on what came before.

```bash
pepe chat assistant
```

When a tool wants to do something sensitive (run a shell command, write a file),
the console asks you to approve it before it runs, and tells you what makes the
call risky (for example "writes to a file" or "accesses the network").

### Do it by chat

Once an agent holds the `enable_tool` tool, it can add a tool to its own
allowlist in conversation, which is handy right after you install a plugin. The
tool must already exist as a built-in or a plugin. Since this changes
configuration, the call is guarded, so you approve it at the permission prompt.
The new tool is available from the agent's next message.

> You just installed the weather plugin. Turn on the get_weather tool for
> yourself.

## 6. Serve it everywhere

One command puts the same agent behind an OpenAI-compatible HTTP API, a streaming
WebSocket, and a local web dashboard.

```bash
pepe serve --port 4000
```

```bash
✓ Pepe serving on http://localhost:4000  (override with PORT=NNNN)

  OpenAI API : POST http://localhost:4000/v1/chat/completions
  Models     : GET  http://localhost:4000/v1/models
  Health     : GET  http://localhost:4000/health
  WebSocket  : ws://localhost:4000/socket/websocket  (topic agent:default)

   dashboard: open on localhost only; remote clients are blocked until you set a password
```

### Call it like OpenAI

The agent name goes in the `model` field. Any OpenAI SDK or plain `curl` works.

```bash
curl http://localhost:4000/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"assistant","messages":[{"role":"user","content":"hi"}]}'
```

Because it is the standard Chat Completions shape, existing OpenAI client
libraries point straight at it. Here is the same call from a couple of languages.

**Python**

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:4000/v1", api_key="unused")

resp = client.chat.completions.create(
    model="assistant",
    messages=[{"role": "user", "content": "hi"}],
)
print(resp.choices[0].message.content)
```

**Node**

```javascript
import OpenAI from "openai";

const client = new OpenAI({ baseURL: "http://localhost:4000/v1", apiKey: "unused" });

const resp = await client.chat.completions.create({
  model: "assistant",
  messages: [{ role: "user", content: "hi" }],
});
console.log(resp.choices[0].message.content);
```

`GET /v1/models` lists your agents, so a client that fetches available models
sees each agent as one.

<div class="note"><strong>The API is open until you lock it.</strong> With no tokens configured, anyone who can reach the port can call it. Create the first token with <code>pepe token add</code> and every call then needs an <code>Authorization: Bearer</code> header. See the HTTP API page for details.</div>

### The dashboard

Serving also opens a local web dashboard where you can manage agents, models,
channels, scheduled tasks, plugins, traces, and usage without editing the config
file by hand. On localhost it is open by default. If you bind Pepe to a public
address, remote access stays blocked until you set a dashboard password with
`pepe dashboard password '<pass>'`.

## 7. Put it on a chat channel

The same agent can answer people on a messaging platform. Telegram is the
quickest to try. Create a bot with Telegram's BotFather, then hand Pepe the
token.

```bash
pepe gateway telegram setup
pepe gateway telegram
```

The first command stores the token and binds the bot to an agent. The second
starts the poller. From then on, anyone who messages the bot is talking to your
agent, with the same tools and memory it has everywhere else.

Beyond Telegram, Pepe connects to WhatsApp, Slack, Discord, Microsoft Teams, and
Google Chat over each platform's official webhook, plus a generic inbound webhook
for anything else. You can set these up interactively by running `pepe setup` and
choosing Channels, or from the dashboard.

### Do it by chat

An agent that holds the `manage_channel` tool can create and rebind Telegram bots
from a conversation. It never accepts a raw token. You give it the name of an
environment variable that holds the token, which Pepe stores as `${THE_VAR}` so
the secret never reaches the model or the logs. The tool is risky, so the change
goes through the permission gate before it takes effect, and the running poller
reconciles live with no restart.

> Set up a Telegram bot for the sales agent. The token is in the SALES_BOT_TOKEN
> environment variable.

The agent confirms the details, then (on your approval) creates the bot bound to
the `sales` agent, storing its token as `${SALES_BOT_TOKEN}`.

## 8. Automate: scheduled tasks and watches

Pepe can run an agent on a schedule, or watch for a condition and notify you once.

A scheduled task runs a self-contained prompt on a recurring cron schedule.

```bash
pepe cron add
pepe cron list
```

A watch polls a cheap probe and pings you a single time when it passes, then
stops. It survives restarts.

```bash
pepe watch add "site up" --probe "curl -sf https://example.com" --every 120
pepe watch list
```

Both also have a home in the dashboard.

### Do it by chat

An agent with the `schedule_task` tool can create recurring jobs in
conversation, and one with the `watch` tool can set up one-shot notifications.
Both are gated: the agent drafts the details, confirms them with you (what, when,
which timezone, where to report), and applies the change only after you approve
it at the permission prompt.

Scheduling:

> Every weekday at 8am, check our status page and send me a one line summary.

The agent writes a self-contained task with a cron schedule (`0 8 * * 1-5`) and a
timezone, confirms it, and saves it once you approve. It reports back to the same
chat by default.

Watching:

> Tell me as soon as example.com comes back up.

The agent creates a one-shot probe watch that polls the site on a timer and
messages you once when it succeeds, then stops.

## Where your setup lives

Everything you did above is now in `~/.pepe/config.json`: the model connection,
the agent, and any channels. No database, no migrations. To move a setup to
another machine, copy that file and set the same environment variables your
`${VAR}` references point to.

```bash
pepe config
```

That prints the config path and a summary of what is defined.

## Next steps

- [Agents and tools](./agents/). What an agent is made of and how it decides
  which tools to call.
- [HTTP API](./api/). Streaming, tool calls over the wire, and locking the API
  with tokens.
- [Channels](./channels/). Telegram, WhatsApp, Slack, Discord, Teams, and Google
  Chat in depth.
- [Scheduled tasks](./scheduled/). Run an agent on a recurring schedule, and
  one-shot watches.
- [Security and permissions](./security/). The approval gate, sandboxing the
  shell tools, and the dashboard password.
- [Plugins](./plugins/). Add your own tools and channels without rebuilding.

<div class="note"><strong>Running more than one tenant?</strong> Pepe can scope agents, models, and channels to a company so tenants stay isolated. Everything you set up above lives in the default scope, called Principal. Add <code>--company NAME</code> to a command to work inside a specific one.</div>
