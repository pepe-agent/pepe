---
title: CLI reference
description: Every pepe command, grouped by what it manages: model connections, agents, projects, tokens, the dashboard, and more.
---

Everything in Pepe is reachable from the command line, grouped here the way you'd
actually reach for it: by what you're trying to do, not alphabetically. Every example
uses the installed `pepe` binary; from a source checkout use `mix pepe` instead, both
take the same subcommands.

```bash
pepe help              # the full command list
pepe help <group>       # e.g. pepe help agent
```

## Setup

```bash
pepe setup   # first run: guided wizard (language -> model -> agent -> Telegram)
              # later runs: a menu to add or reconfigure any part
```

## Model connections

```bash
pepe model                       # show the default, switch among saved ones, or add a new one
pepe model add openai            # guided: pick provider -> auth method -> model
pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat --default      # fully manual
pepe model providers             # list known providers (OpenAI, Anthropic, Gemini, ...)
pepe model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
pepe model list                  # list saved connections
pepe model test [NAME]           # ping a connection to verify the key/endpoint work
pepe model reconnect openai      # sign back in to fix a broken connection, keeping everything else about it
pepe model remove openrouter
pepe model default openai
```

Already pay for ChatGPT/Codex or Claude Pro/Max? Add it by **signing in with that
account** instead of pasting an API key: `pepe model add openai` -> "ChatGPT / Codex
subscription" opens your browser, you log in, and Pepe takes it from there. See
[Models](../models/).

If that connection ever stops working (a login that expired, or got signed out
elsewhere), `pepe model reconnect NAME` signs back in and fixes it in place. Nothing
else about the connection changes, so every agent using it keeps working with no extra
setup. Don't remove and re-add it to fix this: that starts from scratch and loses any
pricing or custom settings you had on it.

## Agents

```bash
pepe agent add assistant \
  --prompt "You are a helpful coding agent." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
pepe agent list
pepe agent route assistant helper    # let assistant message another agent (see Routing)
pepe agent manage boss assistant     # let boss administer assistant ("*" = all)
pepe agent rename assistant helper   # relabel + move its workspace dir
pepe agent remove helper
pepe agent default assistant
```

See [Agents](../agents/) for what each option does.

## Projects (running more than one client or team)

If you're running Pepe for several clients or teams from one install, each one is a
**project**, with its own agents and its own data, walled off from every other project.
Skip `--project` and everything just uses the one default project, exactly like a
single-client install always has. See [Projects](../projects/).

```bash
pepe project add acme --description "Acme Inc"     # create a new client/project
pepe project list
pepe project rename acme umbrella                  # rename it; nothing else breaks
pepe agent add sales --project acme --prompt "..."  # agent "acme/sales"
pepe agent list --project acme                     # only Acme's agents
pepe agent list --all                              # every project
pepe run acme/sales "hello"                        # run it by its handle
pepe project remove acme --force                   # delete the project + its agents
```

## Running

```bash
pepe run "list the files here and summarize the project"   # one-shot, streams to stdout
pepe run assistant "hello"                                 # pick an agent explicitly
pepe chat                            # interactive conversation, remembers what was said
pepe chat --agent assistant          # ...with a specific agent (or: pepe chat assistant)
pepe goal "ship the release notes" \
  --criteria "CHANGELOG has a dated section" --max-attempts 5   # keep going until it's actually done
pepe serve --port 4000               # start the API, dashboard and WebSocket together
pepe serve install [--port 4000]     # keep it running in the background permanently
pepe serve status                    # is it installed and running?
pepe serve uninstall                 # stop and remove it
```

`goal` doesn't stop at the first attempt: an independent reviewer checks the result
against `--criteria` and Pepe keeps trying (up to `--max-attempts` times) until it
actually passes. Use `--judge MODEL` to have a different model do the checking. See
[Goals](../goals/).

`serve install` makes Pepe start on its own and stay running in the background, through
logouts, reboots, even a crash. It only works from the installed `pepe` app, not from a
source checkout.

`chat` (also called `tui`) opens a conversation right in your terminal that remembers
context as you go. Type `/help` inside it for the full list of shortcuts: new
conversation, undo, switch agent or model, and more.

## Telegram gateway

```bash
pepe gateway telegram setup      # interactive: bot token, who's allowed to talk to it, which agent
pepe gateway telegram            # run it in the foreground
```

See [Telegram](../telegram/) for how access and multiple bots work.

## API access tokens

Keys other apps use to talk to Pepe over HTTP or WebSocket. With none created, only
requests from the same machine are allowed; the moment you create one, every request
needs a valid token. A token can be limited to one project (`--project`) or one agent
(`--agent HANDLE`). See [HTTP API](../api/).

```bash
pepe token add --project acme --label "acme mobile app"   # prints the key once, save it now
pepe token add --agent acme/sales --label "one integration"
pepe token add --agent acme/sales --widget \
  --allowed-origin https://example.com     # safe to put in a public page's source code
pepe token list                        # id, scope, permissions, label
pepe token update <id> --greeting "Hi! How can I help?"
pepe token revoke <id>
```

Scope decides *whose* data a token can reach; permissions decide *what* it's allowed to
do with it. That means you can hand someone a token that only reads billing reports,
without it being able to chat with an agent at all. See [Usage and billing](../billing/).

```bash
# a billing-only token: reads /v1/usage, can't run an agent, and only sees what the
# client actually pays (--prices list hides your margin; --prices all shows it too)
pepe token add --project acme --no-chat --usage --prices billable

pepe token permissions <id> --prices list   # change it in place, the key itself stays the same
pepe token permissions <id> --no-usage
```

## Watches ("tell me once X happens")

Checks something on a schedule and notifies you **once**, the moment it's true, then
stops on its own. See [Watches](../watches/).

```bash
pepe watch add "site up" --probe "curl -sf https://x" --every 120
pepe watch list
pepe watch pause <id> | resume <id> | cancel <id>
```

## Scheduled tasks

Agent jobs that run on a recurring schedule, like a cron job. See [Scheduled
tasks](../scheduled/).

```bash
pepe cron list
pepe cron add --name "daily digest" --prompt "..." --schedule "0 8 * * *"
pepe cron run <id>          # run it right now, outside its schedule
pepe cron logs <id>
```

## Flows (repeat a proven sequence without re-thinking it)

Once an agent has solved something the same way a couple of times, turn that sequence
into a named `flow` that replays it directly next time, faster and without asking the
model to figure it out again from scratch. See [Flows](../flows/).

```bash
pepe flow list AGENT
pepe flow promote NAME --agent AGENT --from ID1,ID2[,...] [--overwrite]
pepe flow show AGENT NAME
pepe flow remove AGENT NAME
pepe flow run AGENT NAME                                    # run it now
pepe flow schedule AGENT NAME --schedule "..." [--timezone TZ] [--deliver ...]
```

## Learning

```bash
pepe timelearn [AGENT]                 # what the agent has picked up, over time
pepe learn consolidate [AGENT]         # tidy that up right now
pepe learn auto [AGENT] [--at CRON]    # do that automatically every night (--off to stop)
pepe learn status                      # which agents are set to do this
```

See [Learning](../learning/) for what actually gets remembered.

## Usage, billing and traces

```bash
pepe usage                                  # tokens & cost by cycle, per project
pepe usage --project acme --granularity day
pepe usage runs [--project acme] [--source telegram] [--agent H] [--limit N]
                                             # one line per conversation
pepe usage runs <id>                        # that conversation, step by step
pepe usage export --project acme            # a client invoice (Markdown, or --format csv)
pepe usage prices [--refresh]               # see or refresh current model prices
pepe traces [--project NAME] [--limit N]    # recent activity, any channel
pepe traces <id>                            # replay one run step by step
```

The same numbers are available over HTTP with a usage-scoped token. See [Usage and
billing](../billing/).

## Tool servers, plugins and privacy hooks

```bash
pepe mcp add NAME --command npx --args "..."       # a local tool server
pepe mcp add NAME --url URL --header "K: V"        # a remote tool server (HTTP)
pepe mcp list | tools NAME | remove NAME           # inspect and manage
pepe mcp login|logout NAME                         # sign in to a remote tool server
pepe plugin list | install | scan | remove         # extra tools & channels
pepe plugin route list | enable NAME | disable NAME  # a plugin's own web endpoint
pepe skill list | search | install | update | remove | audit | tap  # skill marketplace
pepe db add | list | remove              # let an agent query an external database
pepe slot list | set | clear             # which plugin handles a given capability
pepe policy list                         # installed permission rules and where they apply
pepe policy scope NAME --agents a,b [--projects x,y] | --clear   # limit where a rule applies
pepe hooks list                          # available privacy hooks
pepe hooks generate "redact CPFs" [--model NAME] [--save]   # have AI write one for you
```

See [MCP](../mcp/), [Plugins](../plugins/), [Skills](../skills/), [Database](../database/)
and [Privacy and hooks](../privacy/).

## Quality and operations

```bash
pepe eval [SUITE]                # run a set of test prompts against an agent
pepe doctor [--offline]          # check that everything is set up correctly
pepe review [approve|reject ID]  # approve or reject changes an agent made on its own
pepe backup [--output FILE.tgz]  # save everything (config, agents, conversations, database)
pepe backup verify FILE.tgz      # double-check a backup is intact
pepe restore FILE.tgz [--force]  # bring a backup back
pepe migrate SOURCE [--dry-run]  # bring models/agents over from another tool
pepe update                      # update to the latest version
pepe browser install             # set up the browser an agent can use
```

See [Evals](../evals/), [Backup](../backup/) and [Browser](../browser/).

## Dashboard

A password is optional. Without one, the dashboard only opens on the same machine it's
running on; anyone connecting from elsewhere is blocked. See [Auth](../auth/) and
[Dashboard](../dashboard/).

```bash
pepe dashboard                            # see the current settings
pepe dashboard password                   # set one, typed hidden, nothing shows on screen
pepe dashboard hosts app.example.com      # allow reaching it by a domain name (--clear to reset)
pepe dashboard trusted-proxies 10.0.0.0/8 # needed if it's running behind a reverse proxy
```

## Misc

```bash
pepe tools     # list every tool an agent can use
pepe config    # where the config file lives, and a quick summary
pepe help      # full command help (or: pepe help <group>)
```
