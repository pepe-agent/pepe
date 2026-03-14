# Web dashboard

A Phoenix LiveView dashboard at **`/`** - a live list of sessions on the left and a
streaming chat panel on the right. Pick a session to read its history and talk to
its agent; replies stream in token-by-token. `New chat` starts a fresh session, and
each session shows its agent, model and turn count. The left sidebar mirrors the
CLI, so almost everything you can do with `mix pepe` you can do here:

- **Chat** - talk to a session (risky tools prompt inline).

- **Companies** - create/edit/delete tenant scopes and their billing markup (see **Companies**).

- **Agents** - create/edit/delete agents: persona, model, tools, routes, admin scope,
  default.

- **Models** - add/remove/edit model connections, set per-model prices, pick the default.

- **Usage & billing** - token usage and cost by cycle, per company (see **Usage metering & billing**).

- **Learning** - the TimeLearn timeline (see **Learning**).

- **Scheduled** - create/run/manage scheduled tasks (see **Scheduled tasks**).

- **Watches** - one-shot "notify me when X" (see **Watches**).

- **Channels** - add/remove/edit Telegram bots, applied live (see **Telegram -> Multiple bots**).

- **MCP** - external tool servers (see **MCP servers**).

- **Config file** - edit `~/.pepe/config.json` inline, validated on save.

```bash
mix assets.build          # once (builds css/js)
mix pepe serve          # API + dashboard + gateways, one process
# open http://localhost:4000
```

Because sessions are in-process, run everything from the **one** `mix pepe serve`
process and the dashboard sees every session - including the ones from Telegram.
Risky tools are authorized inline on the dashboard too: the run pauses and shows an
allow/deny prompt (the web version of the Telegram buttons), unless the agent has
pre-approved the tool (the omnipotent primary agent never prompts).

---

[Back to the docs index](../README.md#documentation)
