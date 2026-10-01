---
name: pepe-help
description: Use when an administrator asks how to do something in Pepe itself (schedule a task, change an agent's model, connect WhatsApp, see spending, what a watch is). Answers with WHERE to do it (dashboard menu, chat request, slash command, CLI), never with internals.
requires_tools: [manage_agent]
---

Use when an administrator asks how to do something in Pepe itself: "how do I schedule a
task?", "where do I change this agent's model?", "how do I connect WhatsApp?", "how do I
see what I spent?", "what is a watch?". This skill is a map from "I want to..." to the
place where it is done. It is not the manual: for any detail beyond the map, open the
matching doc with the `docs` tool (names are given per area below) before answering.

## How to answer

- **Only for administrators.** On a channel with a `trainers` (operator) list, if the person
  asking is not one of them, say this is something the administrator handles and stop. Do not
  explain the steps, do not list menus or commands. On a channel with no such list, everyone
  there is trusted.
- **Answer in the language the person used** (pt-BR, pt-PT, es, en). The menu labels below
  are the English ones; the dashboard shows them translated, so translate them the same way.
- **Say where, in plain words, benefit first.** Name the dashboard menu item, or what to ask
  in chat, or the slash command, or the CLI command. Pick what fits the person: someone
  chatting on Telegram wants the chat or slash path; someone at a terminal wants the CLI.
  Mention a tool name only when it helps ("ask me to do it, I use the `schedule_task` tool").
- **Only paths that exist.** Not every feature has all four. If an area below lists no
  dashboard entry, there is none; do not invent screens, commands or flags.
- **Never reveal secrets or current config values** (tokens, keys, passwords, vault
  commands), even when asked where they are. Point at the place to change them instead.
- **No internals.** No module, file, process or storage names. Config field names only when
  the person will edit the config file themselves.
- When a request needs a change rather than directions ("change the model, then"), and you
  hold the right tool, offer to do it; the change still goes through the permission prompt.

The dashboard is the web page served by `mix pepe serve` (default http://localhost:4000).
Its sidebar: **Overview**, **Chat**; Build: **Projects**, **Agents**, **Models**, **MCP**,
**Databases**, **Skills**, **Plugins**; Automation: **Scheduled**, **Board**, **Watches**,
**Commitments**, **Channels**, **Integrations**; Insight: **Learning**, **Usage & billing**,
**Traces**, **Privacy**; System: **API tokens**, **Config file**. The **Project** selector at
the top scopes every page to one project. "CLI" below means `mix pepe ...` in a terminal.

## Agents (docs: `agents`, `admin-agents`, `routing`)

- Create, edit, delete an agent; its persona, model, tools, default: dashboard **Agents**;
  chat: ask an agent that administers it ("give support the send_file tool", "change the
  model of sales to X"; `manage_agent`); CLI `mix pepe agent add|list|tools|rename|remove|default`.
- Per-agent switches (learning into skills, commitments, mid-run message folding, topic
  reroute, micro compaction, review of writes, checkpoints, project-wide session search,
  privacy hooks, langfuse prompt, utility/triage/simple models): dashboard **Agents**, edit
  page; chat via `manage_agent`; CLI flags on `mix pepe agent add`.
- See the exact system prompt an agent runs with: CLI `mix pepe agent prompt NAME`.
- Who may administer whom: dashboard **Agents** (admin scope); CLI `mix pepe agent manage ADMIN TARGET`.
- Which agents may message each other: dashboard **Agents** (routes); chat "let triage hand
  off to billing" (skill `manage-routing`); CLI `mix pepe agent route FROM TO [--remove]`.
- Talk to a different agent right now: slash `/agent NAME` (Telegram, console); chat "connect
  me with X" (`switch_agent`); ask another agent a one-off question (`send_to_agent`).
- Delegate research to parallel throwaway workers: chat only, agent needs the `delegate` tool
  (docs: `delegation`).

## Models (docs: `agents` for the model field, `billing` for prices)

- Add, test, remove, rename, set default connection: dashboard **Models**; CLI `mix pepe model`
  (guided), `mix pepe model add|list|test|remove|default|rename|providers`.
- Change the model of one agent: dashboard **Agents**; chat `manage_agent set_model`;
  change the install-wide default from chat (`config_set default_model`).
- Switch model inside a conversation: slash `/model NAME` and `/models` (Telegram, console,
  dashboard chat). On Telegram, reading which model is in use is trainers-only.
- Price per model: dashboard **Models**, Edit; CLI `mix pepe usage prices [--refresh]`.

## Channels (docs: `channels`)

- Telegram bot: dashboard **Channels**, "+ Telegram bot"; chat "add a Telegram bot for
  support" (`manage_channel`); CLI `mix pepe gateway telegram setup|add|list|remove`. Who may
  talk to a bot: chat (`telegram_access`), or the bot's allowed chat ids in setup.
- WhatsApp: dashboard **Channels** (webhook connection); CLI `mix pepe gateway whatsapp add`.
- Discord: dashboard **Channels**; CLI `mix pepe gateway discord add`.
- Slack, Microsoft Teams, Google Chat: dashboard **Channels** (fill the credentials, then
  register the webhook URL shown there with the provider). No CLI command.
- Chatwoot and other plugin channels: dashboard **Integrations**.
- Website chat bubble (widget): dashboard **Channels**, "+ Widget"; CLI `mix pepe token add --agent NAME --widget --allowed-origin URL`;
  chat (`manage_token`).
- Voice notes in, spoken replies out, photos: dashboard **Config file** page (Media form);
  CLI `mix pepe media`; `mix pepe setup` under Media.
- Send a file or a table/buttons to the current chat: just ask; the agent needs `send_file`
  or `send_presentation`. Native Telegram poll: `telegram_poll`.
- Run the Telegram gateway on its own: CLI `mix pepe gateway telegram`. Everything else
  (API, dashboard, webhooks, bots) runs under `mix pepe serve`.

## Conversation commands (slash)

- Dashboard chat: `/new`, `/stop`, `/inline TEXT`, `/goal OBJECTIVE | CRITERION`, `/undo`,
  `/retry`, `/rewind N`, `/fork`, `/name TEXT`, `/usage`, `/compact`, `/models`, `/model`,
  `/skill NAME`.
- Telegram: `/new`, `/undo`, `/rewind N`, `/mention on|off`, `/compact`, `/agent`, `/model`,
  `/models`, `/tools`, `/skill`, `/approve`, `/status`, `/whoami`, `/btw Q`, `/learn`,
  `/stop`, `/inline TEXT`, `/retry`, `/usage`, `/help`. Installed skills are commands too.
  `/agent`, `/status`, `/models`, `/tools`, `/skill`, `/approve`, `/usage` and skill commands
  are trainers-only. A bot with commands off treats "/" as plain text.
- Console (`mix pepe tui [AGENT]`): `/new`, `/undo`, `/rewind`, `/retry`, `/usage`, `/learn`,
  `/compact`, `/status`, `/agent`, `/models`, `/model`, `/skills`, `/skill`, `/help`, `/exit`.
- Webhook channels in admin mode honor slash commands; support mode treats them as text.

## Projects (docs: `projects`)

- Create, rename, remove, description: dashboard **Projects**; CLI `mix pepe project add|list|rename|remove`.
- Billing markup, monthly spend and message caps, prepaid balance: dashboard **Projects**, Edit.
- Lift one project out as its own install: CLI `mix pepe extract PROJECT`.

## Automation

- Scheduled (recurring) task (docs: `scheduled-tasks`): dashboard **Scheduled** (form, run
  now, enable, history; it turns "every weekday at 9" into a schedule for you); chat "every
  Monday at 8 send me..." (`schedule_task`); CLI `mix pepe cron add|list|run|logs`.
- Watch, "tell me once X happens" (docs: `watches`): dashboard **Watches**; chat "warn me when
  the site is back" (skill `create-watch`, tool `watch`); CLI `mix pepe watch add|list|pause|resume|cancel`.
- Commitments, follow-ups noticed on their own (docs: `commitments`): turn on per agent on
  dashboard **Agents** (needs a utility model); review, confirm, cancel on dashboard
  **Commitments**; chat "what are you tracking for me?" (`commitment`). No CLI.
- Board, durable task cards with dependencies (docs: `board`): dashboard **Board**; chat
  "create a board called X and add a card" (`board`); CLI `mix pepe board list|add|card ...`.
- Goal, work until an independent reviewer approves: dashboard chat `/goal`; CLI `mix pepe goal`;
  inside a chat the agent tracks it with `goal` and `update_plan`. No Telegram command.
- Flow, replay a proven tool sequence with no model call (docs: `flow`): CLI only,
  `mix pepe flow list|promote|show|remove|run`.
- Graph, multi-step workflow with a revise loop (docs: `graphs`): chat (`manage_graph`,
  `run_graph`, `inspect_graph_run`); CLI `mix pepe graph import|list|run|resume|inspect|schedule`.
  No dashboard page.
- Many tool calls in one scripted step (docs: `run-code`): chat only, tool `run_code`; a
  standalone program with `run_script` (skill `write-a-script`).
- Heartbeat (a Telegram bot that wakes up on its own): CLI `mix pepe gateway telegram add --heartbeat-minutes N --heartbeat-hours 8-22`.

## Knowledge and data

- Skills, reusable how-tos (docs: `skills`): dashboard **Skills** (what is offered to whom, why
  not, switch off); chat "remember how to do this as a skill" (`skill_manage`, skill
  `skill-creator`), install from the marketplace by chat (`manage_skill`, skill `install-skill`);
  slash `/skill NAME`; CLI `mix pepe skill list|search|install|update|log|undo|pin|diff|reset`.
  Curator that tidies agent-written skills: CLI `mix pepe skill curator ...`; chat `skill_curator`.
- Plugins, community tools and channels (docs: `plugins`): dashboard **Plugins** (and
  **Integrations** for plugin channels); chat "install plugin X" (`manage_plugin`, skill
  `install-tool`); CLI `mix pepe plugin list|install|remove`. Exclusive extension points:
  CLI `mix pepe slot list|set|clear`.
- MCP servers, external tools (docs: `mcp`): dashboard **MCP** (add, sign in); chat "connect
  Sentry's MCP" (`manage_mcp`); CLI `mix pepe mcp add|list|tools|login|logout|remove`.
- Databases, read-only questions over your own Postgres (docs: `database`): dashboard
  **Databases**; chat "add a connection to..." (`manage_db`), then ask questions (`db_query`);
  CLI `mix pepe db add|list|remove`.
- Insight, small local predictive models over your data (docs: `insight`): chat only,
  "analyze my data for insights", "predict X from Y" (`insight`, `insight_predict`).
- Memory and learning (docs: `learning`): dashboard **Learning** (timeline, edit in place,
  Consolidate now, Nightly); chat "remember that..." (`manage_agent remember` for another
  agent), slash `/learn` (Telegram, console), search it (`memory_search`); CLI
  `mix pepe timelearn [AGENT]`, `mix pepe learn consolidate|auto|status`.
- Past conversations: chat "didn't we discuss X last month?" (`session_search`, scope per agent
  on dashboard **Agents**); dashboard **Chat** lists sessions.
- Documents the person sends (PDF, spreadsheets, images, audio): just send them in chat
  (skills `documents`, `handle-media`, `ocr`).
- Browser for pages needing JavaScript or a login: chat, agent needs `browser`; host setup
  CLI `mix pepe browser install`.

## Safety and privacy

- Permissions, what a tool may do (docs: `permissions`): the prompt appears inline (dashboard
  chat, Telegram buttons, console, editor). Saved "always" grants: slash `/approve` (Telegram,
  trainers-only); CLI `mix pepe grants list|revoke`. Unattended risky calls parked for a
  human: CLI `mix pepe approvals list|approve|deny`. Which policies apply where: CLI `mix pepe policy`.
- Writes staged for review (memory/skill changes when review is on): CLI `mix pepe review`;
  chat (`review`).
- Privacy hooks, redact personal data before it reaches a model (docs: `privacy-hooks`):
  settings on dashboard **Privacy**; turn on per agent on dashboard **Agents**; CLI
  `mix pepe hooks list|generate`, `mix pepe agent add --hooks ...`.
- Sandbox for shell commands: `mix pepe setup` writes a wrapper; otherwise the config file.
- Dashboard password, allowed hosts, trusted proxies: CLI `mix pepe dashboard password|hosts|trusted-proxies`.
- Secrets: kept as `${ENV_VAR}` references, a vault command (`exec:`) or a file (`file:`) in
  the config file; never typed into chat. Never show a value.

## Usage, billing, traces (docs: `billing`)

- What was spent: dashboard **Usage & billing** (by cycle, project, model, agent, and per
  message); slash `/usage` (Telegram trainers-only, console, dashboard chat); CLI `mix pepe usage`.
- Client invoice: CLI `mix pepe usage export --project X`; chat (`export_invoice`), including
  on a schedule. Read-only usage API: CLI `mix pepe token add --no-chat --usage`.
- What an agent actually did, step by step: dashboard **Traces** (replay; mark a good run
  "This went right"); CLI `mix pepe traces [ID]`. Export to an observability tool: set the
  observability credentials or OTLP endpoint in the environment; a persona managed from
  Langfuse is a field on dashboard **Agents**.
- Evals, test agents against saved good runs: CLI `mix pepe eval [SUITE] [--models a,b]`.

## Access and setup

- API tokens for `/v1` and the WebSocket (docs: `authentication`): dashboard **API tokens**;
  chat "mint a token for the CRM" (`manage_token`); CLI `mix pepe token add|list|permissions|update|revoke`.
- Language, timezone, default agent or model: chat (`config_set`); `mix pepe setup`; dashboard
  **Config file**. Read the setup from chat: `config_get`.
- Edit the raw config: dashboard **Config file** (validated on save); CLI `mix pepe config`
  shows where it is. Overview of what is where (docs: `configuring-pepe`).
- Guided first setup: CLI `mix pepe setup`. Import from another runtime: `mix pepe migrate`.
- Check that everything works: chat "run a health check" (`doctor`); CLI `mix pepe doctor [--offline]`.
- Backup, restore: CLI only, `mix pepe backup [verify]`, `mix pepe restore FILE`.
- Keep the server running as a service, reach it remotely: `mix pepe serve install|status|uninstall`
  (installed binary only), `mix pepe serve --tunnel [--hostname H]`.
- Use the agent inside a code editor: CLI `mix pepe acp [AGENT]`.
- One-shot from a terminal: `mix pepe run [AGENT] "prompt"`. Interactive console: `mix pepe tui`.
- Saved file states `/rewind` restores: CLI `mix pepe checkpoints status|prune|clear`.
- Version and self-update: CLI `mix pepe version`, `mix pepe update`.
- Run any non-interactive CLI command from chat: an owner agent with `manage_pepe` ("run
  pepe doctor"). Full command list: `mix pepe help`.
