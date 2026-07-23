---
title: Agents
description: Define an agent from a prompt, a model, and a set of tools, then let the runtime call the model, run tools, and loop until it has an answer.
---

## What an agent is

An agent is a small, declarative definition. It has a name, a system prompt that
gives it a persona, a model connection to think with, and an allowlist of tools it
is permitted to call. A handful of extra knobs (an iteration limit, a temperature,
who it may talk to, who it may administer) round it out. That is the whole thing.
The agent holds no logic of its own. The Pepe runtime does the work: it calls the
model, runs any tools the model asks for, feeds the results back, and repeats until
there is a final answer.

Every agent lives as one entry in a single JSON file at `~/.pepe/config.json`.
There is no database. You can create and edit agents three ways, and they all write
to the same file:

1. The `pepe` command-line tool.
2. The dashboard.
3. Plain conversation, by talking to an agent that has the relevant management tool.

Here is a complete agent as it appears on disk:

```json
{
  "agents": {
    "assistant": {
      "description": "General-purpose helper",
      "model": "openrouter",
      "system_prompt": "You are a concise, helpful assistant.",
      "tools": ["bash", "read_file", "write_file", "web_search"],
      "auto_approve": [],
      "can_message": [],
      "can_manage": null,
      "hooks": [],
      "max_iterations": 12,
      "temperature": null
    }
  }
}
```

## Your first agent

An agent needs a model connection before it can think. If you have not created one
yet, the guided setup walks you through picking a provider, signing in, and choosing
a model:

```bash
pepe setup
```

Then define an agent with a prompt and some tools:

```bash
pepe agent add assistant \
  --model openrouter \
  --prompt "You are a concise, helpful assistant." \
  --tools bash,read_file,write_file,web_search
```

Run a one-shot prompt against it. The reply streams to your terminal as it is
produced:

```bash
pepe run assistant "What files are in the current directory?"
```

That single command triggers the full loop. The agent decides it needs to look at
the filesystem, calls the `list_dir` or `bash` tool, reads the result, and answers
you in plain language.

<div class="note"><strong>From the dashboard.</strong> The Agents section of the web
dashboard does the same thing with a form: name, persona, model, a checklist of
tools, and the admin scope. It writes the identical entry to
<code>~/.pepe/config.json</code>, so you can mix and match the CLI, the dashboard,
and hand-editing freely.</div>

### Do it by chat

Any agent that has the `manage_agent` tool can create and configure other agents
through conversation. This is how the very first agent (see "The owner agent" below)
lets you build out the rest of your fleet without touching the CLI. A message like:

```text
Create a new agent called researcher. Give it a persona focused on careful
web research, point it at the openrouter model, and turn on web_search and
fetch_url.
```

The agent calls `manage_agent` with `action: "create"`, then `set_persona`,
`set_model`, and `add_tool` for each capability. `manage_agent` is a risky tool: it
passes through the permission gate, so on a surface that can ask (the console, a chat
channel) the runtime asks you to authorize the change before it is written, and the
tool itself is instructed to confirm the plan with you first. An agent may only
manage the agents inside its `can_manage` scope (covered under [Administering agents](#administering-agents)
below); asking it to touch one outside that scope is politely refused.

## The fields, one by one

| Field | What it does | Default |
|-------|--------------|---------|
| `name` | The agent's addressable label. In a project it becomes a handle like `acme/assistant` (see below). The agent also carries a stable internal id, so this name can be changed without breaking any binding. | required |
| `description` | A short human note. Never sent to the model. | none |
| `model` | The name of a model connection. Leave it unset to use the project's default model. | project default |
| `system_prompt` | The persona and instructions the agent runs with. | `You are Pepe, a helpful AI agent.` (a seed prompt) |
| `tools` | The list of tool names this agent may call. Only these are offered to the model. | all tools when `--tools` is omitted at creation |
| `auto_approve` | Tools this agent may run without asking for permission. `["*"]` means every tool. | `[]` |
| `can_message` | Other agents this one may send messages to (a directed route). | `[]` |
| `can_manage` | Which agents this one may administer. See [Administering agents](#administering-agents). | `null` (itself only) |
| `hooks` | Message-flow transforms to apply, such as PII redaction. | `[]` |
| `max_iterations` | The hard cap on how many model-plus-tool rounds one turn may take. | `12` |
| `temperature` | Sampling temperature passed to the model. Unset uses the provider's own default. | provider default |
| `triage_model` | A model connection, judging complexity before a session's first turn. See [Complexity-based model routing](#complexity-based-model-routing). | none (off) |
| `simple_model` | The model connection to downgrade to when `triage_model` judges a chat simple. | none |

## How the tool-calling loop runs

When you send a turn to an agent, the runtime does this:

1. It calls the model with the conversation so far and the JSON specs for every tool
   on the agent's allowlist.
2. If the model replies with a final answer, that answer is returned and the loop
   ends.
3. If the model instead asks to call one or more tools, the runtime runs each tool,
   appends the results to the conversation, and goes back to step 1.
4. This repeats until the model produces a final answer or the loop reaches
   `max_iterations`. If the cap is hit, the turn ends with the note
   `(stopped: max iterations reached)`.

Because the results are fed back in, the model can chain steps. It can read a file,
decide it needs another, read that too, then write a summary, all inside one turn.
The iteration limit is the guardrail that keeps a confused agent from looping
forever.

Two other gates sit in front of the model call. An agent whose model requires
redaction refuses to run unless the agent has a redaction hook enabled, and a project
that has hit its monthly spend cap (or its monthly customer-message cap, a separate
limit) stops here with no new model calls or replies. Both fail the turn cleanly
rather than silently proceeding; see Billing & limits for how those caps are set.

<div class="note"><strong>Streaming and events.</strong> As the loop runs it emits
lifecycle events: a streamed text fragment (<code>assistant_delta</code>), a full
assistant message (<code>assistant</code>), a tool call (<code>tool_call</code>), a
refused tool (<code>tool_denied</code>), a tool result (<code>tool_result</code>), a
model failover (<code>failover</code>), a token-usage record (<code>usage</code>), a
final answer (<code>done</code>), or an error (<code>error</code>). The CLI, the
WebSocket, and the messaging channels all render these live, which is why you see
typing and tool activity as it happens rather than one blob at the end.</div>

## Tools and the permission gate

A tool is a capability. An agent can only do what its `tools` list allows. Give an
agent `read_file` but not `write_file` and it can look but not touch.

List every tool available in your install:

```bash
pepe tools
```

The built-in set covers the common ground:

| Tool | What it does |
|------|--------------|
| `bash` | Run a shell command. |
| `run_script` | Write and run a short program in Python, Node, Ruby, or Elixir. |
| `read_file`, `write_file`, `edit_file`, `move_file`, `list_dir` | Work with files in the agent's workspace. |
| `fetch_url`, `web_search` | Read a web page or search the web. |
| `send_file` | Deliver a file the agent produced on the current channel. |
| `send_to_agent` | Message another agent (subject to `can_message`). |
| `ask_user` | Ask you to pick one of a few options, as real tappable buttons/menu where the channel supports it. |
| `schedule_task`, `watch` | Create recurring jobs and one-shot "notify me when X" watches. |
| `manage_agent`, `rename_agent`, `enable_tool`, `set_route` | Manage agents, tools, and routing from chat. |
| `manage_channel`, `end_session` | Connect and close messaging channels from chat. |
| `manage_mcp`, `scan_skill`, `skill` | Add external tool servers and skills. |
| `manage_plugin` | Install, scan, list, and remove community plugins (tools, channels) from chat. |
| `config_get`, `config_set`, `doctor` | Inspect and change configuration under guardrails, run diagnostics. |

Some tools are read-only and run freely: `read_file`, `list_dir`, `fetch_url`,
`web_search`, `config_get`, `skill`, `docs`, `doctor`, `scan_skill`, and
`send_to_agent` (which is governed by the `can_message` route allowlist instead).
Everything else, including any plugin tool, is treated as risky and passes through a
permission gate before it executes.

When a risky tool has not been pre-approved and the surface can ask a human (the
console, a chat channel), the runtime asks you to authorize the call. You can answer:

- Allow once. Ask again next time.
- Allow for the rest of this run. Only offered while the run has taken in content
  from outside (see [Security and sandbox](../security/)) - the one kind of
  pre-approval that actually keeps working during that window.
- Allow for the rest of this session. Kept in memory, forgotten on restart.
- Allow always. Persisted on the agent by adding the tool to its `auto_approve`
  list.
- Deny. Never remembered, so it is asked again.

Put a tool on `auto_approve` yourself to skip the prompt from the start. On surfaces
with no human to ask (for example the HTTP API, a webhook, a cron job) a gated tool is
refused rather than run unwatched - only what is already on `auto_approve` executes.

### Asking you to choose

Some questions are better answered with a tap than a typed reply. `ask_user` lets an
agent present a genuine multiple-choice question and get the pick back as part of the
same turn, instead of guessing or ending its turn and hoping the next message answers
the right thing. Telegram renders it as real inline buttons; the console, as a numbered
menu; the dashboard chat, as clickable options. It runs freely - asking a question
carries no risk of its own, so it is never gated - but it only works where there is an
interactive person to ask: the HTTP API, a webhook, or an unattended cron/watch run
refuses the call outright rather than hang waiting for a button nobody can press.

### Do it by chat

An agent that has just installed a plugin, or that wants a capability it does not yet
hold, can enable a tool on itself with `enable_tool`:

```text
Enable the web_search tool for yourself.
```

The agent calls `enable_tool` with the tool name. The tool must already exist as a
built-in or an installed plugin, and the change takes effect on the agent's next
message. `enable_tool` is itself gated, so you authorize the grant before it is
written.

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

## Complexity-based model routing

An agent's own `model` is treated as the good default. Optionally, a cheap raw
classification call can judge whether a chat is simple enough to *downgrade* to
something cheaper, before the real turn even starts. No extra agent to configure,
just two fields:

- `triage_model`: a model connection that classifies the incoming message with a
  fixed, built-in prompt (not a persona you write); Pepe just looks for the word
  "SIMPLE" in its reply.
- `simple_model`: the model connection to downgrade to (and keep, for the rest of
  the session) once the triage verdict is simple.

```bash
pepe agent add assistant \
  --model strong-expensive-model \
  --triage-model cheap-fast-model \
  --simple-model everyday-model \
  --prompt "..." \
  --tools bash,read_file,web_search
```

Triage runs once, on a session's first-ever turn, never again for that same
session; once a chat is judged simple it stays on the cheaper model for the
rest of the conversation (the same mechanism the `/model` command uses to switch
a session's model, just triggered automatically instead of by hand). A complex
verdict changes nothing: the session runs on the agent's own model exactly as it
would with no `triage_model` set at all.

Triage is a best-effort optimization, never a dependency. If the triage model
does not exist, is unreachable, or just takes too long (capped at a few
seconds), the turn proceeds on the agent's own model, silently; a triage
outage never blocks or breaks a conversation. `simple_model` must also be set
for triage to run at all; there would be nowhere to downgrade to otherwise.

Every verdict shows up as its own step on that turn's Trace (the dashboard's
per-run replay), alongside any privacy hook that ran on the message, so you
can see exactly why a session ended up on one model instead of the other.

## The default agent

One agent per scope can be the default. The default is what runs when you do not name
an agent:

```bash
pepe run "summarize this repository"
```

The first agent you create in the default project automatically becomes
the default. Change it at any time:

```bash
pepe agent default assistant
```

## The owner agent

The very first agent created during setup is the owner's own agent, and it is born
fully capable. It gets every tool, it is a super-admin over all other agents
(`can_manage` is `["*"]`), and all of its tool calls are pre-approved (`auto_approve`
is `["*"]`) so it never stops to ask. This is what lets you do real work through chat
from the first minute, including creating and configuring every later agent. Agents
you add afterward are narrower by default: you choose their tools, they manage only
themselves, and their risky calls go through the permission gate.

## Letting agents talk to each other

`can_message` is a directed allowlist. If agent A lists agent B, then A may send B a
message with the `send_to_agent` tool. The reverse is not implied. Add a route from
the CLI:

```bash
pepe agent route triage assistant
```

Now `triage` can hand work to `assistant`. Remove the route with `--remove`. Routes
never cross a project boundary; the CLI refuses `A -> B` when the two are in
different projects.

### Do it by chat

An agent with the `set_route` tool can change routing conversationally. `from`
defaults to the calling agent:

```text
Allow yourself to message the billing agent.
```

The agent calls `set_route` with `action: "allow"` and `to: "billing"`. Routing is
directed, so this does not let `billing` message back. Because it edits config,
`set_route` goes through the permission gate and you authorize the change.

## Administering agents

`can_manage` controls which agents an agent may administer (create, edit,
reconfigure, train) through the `manage_agent` tool. It is closed by default and its
meaning is precise:

- Unset (`null`): the agent may manage only itself.
- Empty (`[]`, set with `--can-manage none`): it may manage nobody, not even itself.
  A locked child, for example a client-facing agent that must not alter itself.
- A list of names: exactly those agents, and no others. Include its own name to let
  it manage itself too.
- `["*"]` (set with `--can-manage "*"`): every agent. An explicit super-admin.

Grant management authority directly:

```bash
pepe agent manage supervisor "*"
```

### Do it by chat

An admin agent uses `manage_agent` to shape the agents in its scope. Its actions are
`list`, `get`, `create`, `set_persona`, `set_model`, `add_tool`, `remove_tool`, and
`remember` (append a durable fact to the target's memory). For example:

```text
Give the support agent the send_file tool and add a note to its memory that
refunds over 200 need a human.
```

The agent calls `manage_agent` with `action: "add_tool"` and then
`action: "remember"`. Every one of these actions is gated: the agent proposes the
change, you authorize it, and only then is it applied. An agent can also rename
itself with the separate `rename_agent` tool ("From now on, call yourself scout"),
which moves its workspace directory and takes effect on the next message.

## Multi-tenant agents with projects

Every agent lives in a project. On a fresh install that is the single **default
project**, which every command falls back to when you omit `--project`, exactly as a
single-tenant install always has. Add a second project to wall a tenant off: its
agents, workspaces, shared space, model connections, and routing are isolated from
every other project.

An agent's real identity is its handle. In the default project the handle is just
the bare name (`assistant`). In another project it is qualified as `project/name`
(`acme/assistant`), so the same bare name can be reused across projects without
collision.

Create a project, then add agents inside it with `--project`:

```bash
pepe project add acme --description "Acme Corp"

pepe agent add support \
  --project acme \
  --model openrouter \
  --prompt "You are Acme's support agent." \
  --tools read_file,web_search
```

Add `--project acme` to any agent command to act inside that scope. Bare peer names
in `--can-message` and `--can-manage` resolve into the agent's own project, so routes
never accidentally cross a tenant boundary. Each project can pin its own default
model and default agent, or share the operator's global provider. An agent is never
promoted to the global default just by being the first one created inside a
non-default project.

Both projects and agents carry a stable internal id, and every binding (routing,
permissions, defaults, crons, bots, tokens) is recorded against that id, not the
name. Renaming a project or an agent relabels it and moves its directory; nothing
that pointed at it dangles.

## Managing agents from the CLI

```bash
# Create an agent. Omit --tools to grant all tools; pass --tools "" for none.
pepe agent add NAME \
  --model MODEL \
  --prompt "..." \
  --tools t1,t2 \
  [--description "..."] \
  [--can-message b,c] \
  [--can-manage x,y | "*" | none] \
  [--hooks pii_redact] \
  [--max-iterations 12] \
  [--temperature 0.7] \
  [--triage-model MODEL] \
  [--simple-model MODEL] \
  [--default] \
  [--project PROJECT]

# List agents in a project, or every agent everywhere.
pepe agent list [--project PROJECT | --all]

# Print the fully-assembled system prompt - not just the persona field, everything Pepe
# builds around it. See "Seeing exactly what the model sees" below.
pepe agent prompt NAME [--project PROJECT]

# Directed messaging: let FROM message TO.
pepe agent route FROM TO [--remove] [--project PROJECT]

# Management authority: let ADMIN administer TARGET (or "*" for all).
pepe agent manage ADMIN TARGET [--remove] [--project PROJECT]

# Rename an agent and move its workspace directory.
pepe agent rename OLD NEW

# Delete an agent.
pepe agent remove NAME [--project PROJECT]

# Set the default agent for a project.
pepe agent default NAME [--project PROJECT]
```

## Running an agent

The same agent is reachable four ways.

**One-shot from the CLI.** No session, streams to stdout.

```bash
pepe run assistant "your prompt here"
```

**Interactive console.** Keeps the conversation, so context carries between turns.
Resume or separate console sessions with `--session KEY`.

```bash
pepe chat assistant
```

**Over HTTP and WebSocket.** Start the server, then call the OpenAI-compatible API or
open a streaming WebSocket. The `model` field of the request names the agent.

```bash
pepe serve --port 4000
```

```http
POST /v1/chat/completions
Content-Type: application/json

{
  "model": "assistant",
  "messages": [{ "role": "user", "content": "your prompt here" }]
}
```

The WebSocket is served at `ws://localhost:4000/socket/websocket`, and the health
check at `GET /health`.

**Through a messaging channel.** Bind an agent to a Telegram, WhatsApp, Slack,
Discord, Microsoft Teams, or Google Chat connection, or to a generic inbound webhook,
and it answers there with the same loop and the same tools.

## Seeing exactly what the model sees

The `system_prompt` field is only the seed. What actually goes to the model as the
system message also includes the agent's persona/identity/boot files if it has them,
a short behavior contract, the current time, and an index of the docs and skills it
knows about - none of which shows up if you only read the field on disk. To see the
whole thing, assembled exactly the way a real conversation would send it:

```bash
pepe agent prompt NAME
```

The dashboard's agent edit page has the same view, under **Assembled prompt** -
collapsed by default, since it can run long.
