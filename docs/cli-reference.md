# CLI reference (`mix pepe`)

> In development use `mix pepe ...`. The standalone `pepe` binary
> (`mix escript.build`, or a Burrito release) takes the same subcommands.

### Setup

```bash
mix pepe setup        # first run: guided wizard (language -> model -> agent -> Telegram)
                        # later runs: a menu to add/reconfigure any part
```

### Model connections

```bash
mix pepe model                       # show the default + switch among saved / add a new one
mix pepe model add openai            # guided: pick provider -> auth method -> model
mix pepe model add openrouter \
  --base-url https://openrouter.ai/api/v1 \
  --api-key '${OPENROUTER_API_KEY}' \
  --model openai/gpt-5-chat --default      # fully manual
mix pepe model providers             # list known providers (OpenAI, Anthropic, Gemini, ...)
mix pepe model models --base-url https://api.openai.com/v1 --api-key '${OPENAI_API_KEY}'
mix pepe model list                  # list saved connections
mix pepe model test [NAME]           # ping a connection to verify the key/endpoint work
mix pepe model reconnect openai      # redo a subscription sign-in in place (new token, nothing else changes)
mix pepe model remove openrouter
mix pepe model default openai
```

ChatGPT/Codex and Claude Pro/Max can be added by **subscription sign-in** -
`mix pepe model add openai` -> "ChatGPT / Codex subscription" opens your browser
(OAuth PKCE), captures the token, and refreshes it automatically. Both work for
inference, not just sign-in: neither subscription speaks the OpenAI Chat protocol, so
Pepe translates transparently. ChatGPT/Codex goes through the OpenAI **Responses API**
and Claude Pro/Max through the Anthropic **Messages API**, both mapped to the same
tool-calling loop, so agents, tools and every surface behave identically. The Anthropic
**API key** path uses the Messages API too (Anthropic is not OpenAI-compatible).

**When the refresh token itself dies** (subscription lapsed mid-session, revoked,
...) the model returns 401/403 and `ensure_fresh/1`'s silent refresh-grant can't
recover it - it just keeps handing back the same dead token. `mix pepe model
reconnect NAME` redoes the full browser sign-in and swaps in a fresh
access+refresh token **without touching anything else** on the connection
(base_url, model id, pricing, headers, fallbacks, name - all untouched), so
every agent/cron already pointing at that name keeps working with no edits.
Don't `model remove` + `model add` to "fix" a dead token - `add` builds a brand
new connection from scratch and drops any pricing/headers/fallbacks you'd set on
the old one; `reconnect` is the non-destructive path.

### Agents

```bash
mix pepe agent add assistant \
  --prompt "You are a helpful coding agent." \
  --tools bash,read_file,write_file,edit_file,list_dir,fetch_url,web_search --default
mix pepe agent list
mix pepe agent route zak helper        # let zak message another agent (see Routing)
mix pepe agent rename assistant zak   # rename + move its workspace dir (~/.pepe/agents/<name>/)
mix pepe agent remove zak
mix pepe agent default assistant
mix pepe agent help                    # (or `mix pepe help agent`)
```

### Companies (multi-tenant, optional)

Host isolated tenants in one deployment. Without `--company`, everything uses the
**root** scope, exactly as a single-tenant install always has - so this is entirely
opt-in. Add `--company NAME` to scope a command to a company; its agents,
workspaces, `shared/` space and models are walled off from every other company (see
**[Companies](companies.md)**).

```bash
mix pepe company add acme --description "Acme Inc"     # create a tenant scope
mix pepe company list
mix pepe company rename acme umbrella                  # re-key everything to a new name
mix pepe agent add vendas --company acme --prompt "..."  # agent "acme/vendas"
mix pepe agent list --company acme                     # only Acme's agents
mix pepe agent list --all                              # every scope
mix pepe run acme/vendas "hello"                       # run it by its handle
mix pepe company remove acme --force                   # drop the company + its agents
```

### Running

```bash
mix pepe run "list the files here and summarize the project"   # one-shot, streams to stdout
mix pepe run assistant "hello"                                 # pick an agent explicitly
mix pepe tui                         # interactive console, keeps the session
mix pepe tui --agent zak             # ...with a specific agent (or: mix pepe tui zak)
mix pepe serve --port 4000           # OpenAI-compatible HTTP API + WebSocket
pepe serve install [--port 4000]     # install as a persistent background service
pepe serve status                    # is the service installed/running?
pepe serve uninstall                 # stop and remove it
```

`serve install` registers `pepe serve` with launchd (macOS) or systemd `--user`
(Linux) so it survives logout/reboot and restarts itself if it crashes - only
works from the installed `pepe` binary, not `mix pepe serve install` (it needs
a stable path to point the service at). `${ENV_VAR}` secrets referenced in your
config aren't inherited by the service's environment automatically; `install`
lists them so you can add them to the generated unit/plist by hand.

`tui` (alias: `chat`) opens a session-backed console - it keeps context across
turns and prints a summary box (agent · model · session) on open. The same slash
commands as the other gateways work: `/new`, `/undo`, `/compact`, `/status`,
`/agent <name>`, `/models`, `/model <name> [session|global]`, `/help`, `/exit`.
Replies stream as they arrive, and a risky tool asks for permission through an
arrow-key menu (see **Permissions**). There's no multi-user concept in a local
console, so `/model` always offers the session-vs-global choice - see
**Model connections** above for what that means.

### Telegram gateway

```bash
mix pepe gateway telegram setup      # interactive: bot token, allowlists, which agent
mix pepe gateway telegram            # run the gateway in the foreground (long-polling)
```

### Misc

```bash
mix pepe tools                       # list available tools (built-ins + plugins)
mix pepe timelearn [AGENT]           # what the agent has learned, on a timeline
mix pepe cron list|add|run|logs ...    # scheduled tasks (see Scheduled tasks)
mix pepe config                      # show config path + a summary
mix pepe help                        # full command help (or: help <group>)
```

---

[Back to the docs index](../README.md#documentation)
