# Watches - "notify me when X" (one-shot)

A **watch** is a durable, one-shot commitment: you ask the agent to *check something
and tell you when it happens*, it watches in the background, messages you **once**
when the condition is met, and then stops. Unlike a heartbeat (a periodic pulse) or a
cron (a recurring job), a watch fires exactly once and cleans itself up.

It's created on demand - the agent calls the `watch` tool when you ask
("avise quando o deploy concluir") - and it's **durable**: it survives a restart and
this session closing, and delivers back on the **channel you asked from**: Telegram
(direct push), a WebSocket session (a `"watch"` event - pass a stable `session` on
join to receive it across reconnects), or the TUI console (printed inline). If that
channel is momentarily unreachable, the message is held and retried until it lands.

The scheduler runs on whichever long-lived surface is up - `serve`, `gateway`, or an
interactive `tui`/`chat`. Run **one at a time** against the same config; two would
both tick and double-fire.

Two cost tiers, chosen at creation so checking stays cheap:

- **`probe`** - a shell command polled every interval, **no LLM per check** (success =
  exit 0, or a substring match). Best for scriptable conditions ("site is back",
  "log contains `Deploy complete`").

- **`agent`** - re-ask the model each check, for conditions that need judgement.

...and the notification (`on_fire`) is either a fixed **template** (no LLM) or an
**agent**-composed message (one LLM call, only when it fires). The powerful combo is a
free probe gating an agent message: poll `curl` for nothing, and only let the model
write the summary the moment it passes.

```bash
# from chat: "avise quando o site x voltar" -> the agent creates a probe watch.
# from the CLI (probe watches):
mix pepe watch add "site x up" --probe "curl -sf https://x" --message "✅ voltou" --every 60
mix pepe watch list
mix pepe watch pause <id> | resume <id> | cancel <id>
```

Manage them three ways - dashboard **Watches** tab, chat ("para o watch do site" ->
the agent lists and cancels via the `watch` tool), or the CLI - all reading the same
durable store (`~/.pepe/config.json`, `"watches"`). The scheduler ticks only while
`serve`/`gateway` is up; the updated state is persisted **before** delivery, so a
crash can't double-fire.

---

[Back to the docs index](../README.md#documentation)
