---
title: Watches
description: Create durable one-shot monitors that notify you when a condition becomes true.
---

## Watches

A watch answers a different question: not "do this on a clock" but "keep an eye on something and tell me the moment it happens." A watch re-checks a condition on a timer and notifies you **once** when it becomes true, then stops. It is durable: it survives a restart and the closing of the session that created it, and it always replies on the channel it was created from.

### Probe versus agent triggers

The cheap part of a watch is the **trigger**, which runs on every interval. Only when the trigger fires does the (possibly expensive) notification run, once. There are two kinds of trigger:

- A **probe** runs a shell command and costs no tokens per check. Success is exit code 0 by default, or you can require a string to appear in the command's output. Use a probe whenever the condition is scriptable (a URL is reachable, a job wrote a file, a log contains a line).
- An **agent** trigger re-asks the agent a yes/no question each interval, one model call per check. Use it only when deciding whether the condition is met needs real judgement.

Because agent checks cost tokens, their minimum interval is higher: 300 seconds for agent triggers, 30 seconds for probes. The default interval is 120 seconds.

### What it sends when it fires

When the trigger finally passes, a watch delivers a message. That message is either a fixed **template** (a piece of text you set up front, no model call), or **composed by the agent** at fire time (one model call, once) so it can include fresh detail like a summary of what actually happened.

The combination worth knowing is a free probe gating an agent-composed message. The `curl` polling costs nothing, and the model is only asked to write the summary at the moment the condition passes.

### Create a watch from the CLI

The CLI creates probe watches. Agent-judged watches are created from chat, where the model is already in the loop.

```bash
pepe watch add "api-up" \
  --probe "curl -sf https://api.example.com/health" \
  --message "The API is back up." \
  --every 120 \
  --deliver "telegram:123456789"
```

- The description (`"api-up"`) becomes the watch id.
- `--probe` is the shell command to poll. Without `--contains`, success means the command exits 0.
- `--contains STR` instead makes success mean that `STR` appears in the command's output.
- `--message` is the text to send when it fires. Omit it for a default confirmation.
- `--every` is the poll interval in seconds (minimum 30).
- `--deliver telegram:<chat>` sends the notification to that chat. Omit it and the notification goes to the application log.

Managing watches:

```bash
pepe watch list                 # all watches, with state and check count
pepe watch pause api-up
pepe watch resume api-up
pepe watch cancel api-up
```

### Do it in the dashboard

Open the **Watches** page under `pepe serve` to see every watch with its state, trigger, interval, and how many checks it has used against its budget. From there you can pause, resume, and cancel a watch. New watches are created from the CLI or by chat, where the trigger and delivery target are set up.

### Do it by chat

Ask in plain language and the agent creates the watch through its `watch` tool. Like `schedule_task`, the `watch` tool has to be in the agent's toolset and goes through the same permission prompt on each create, so the same double opt-in gate applies.

> Let me know when the deploy finishes. Check every few minutes.

For a scriptable check the agent sets up a probe. For something that needs judgement it sets up an agent trigger, phrasing a yes/no question it answers each interval. It can also choose to compose the fire message with the model instead of a fixed template, so the notification carries a real summary rather than a canned line. The `watch` tool's actions are `create`, `list`, `pause`, `resume`, and `cancel`.

To keep things bounded, at most 50 watches can be active at once, and Pepe refuses a new watch whose condition is identical to one already running, so you cannot accidentally stack duplicates. A watch also has a maximum number of checks; if the condition never comes true within that budget, the watch expires quietly instead of polling forever.

### Delivery to the origin channel

A watch records its **origin**, the channel and conversation it was created from, at creation time. When it fires it delivers back there, even after a restart, whether that is a Telegram chat (a direct push), a connected terminal or WebSocket session, or the application log. On a WebSocket the notification arrives as a `"watch"` event on the channel; pass a stable `session` when you join and you will receive it across reconnects, instead of only on the socket that happened to create the watch. In `pepe chat` it is printed inline in the console. If the watch was created over the stateless HTTP API (which has no conversation to message back), it falls back to the log.

Two guarantees make this reliable:

- **At most once.** The watch's new state (usually "done") is saved to disk *before* delivery is attempted. If the process crashes between firing and delivering, it will not re-check and fire a second time. Only the delivery is retried.
- **Deliver when reachable.** If a watch fires while its channel is offline (a terminal session that has disconnected, for example), the message is held and re-sent on every tick until it lands. You get the notification when you come back, without the watch re-checking.

A watch moves through a small set of states over its life: `pending` (still watching), `paused`, `done` (fired and delivered), `expired` (ran out of its check budget), or `cancelled`.

<div class="note"><strong>No database to install, no crontab.</strong> Scheduled tasks stay as plain records in <code>~/.pepe/config.json</code> (under <code>"crons"</code>), with one JSONL run-history file per task under <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. Watches live in the same small embedded SQLite file as commitments, not something you need to install or manage yourself. Either way, there is nothing else to keep running: the whole scheduler is an in-process timer that runs on whichever long-lived surface is up, <code>pepe serve</code>, a gateway, or an interactive <code>pepe chat</code>, and stops when you stop it. Run only one of them at a time against the same config: two would both tick, and a watch would fire twice. Upgrading from an older Pepe that kept watches in <code>config.json</code> itself? Run <code>mix pepe config migrate-data</code> once to bring the old ones over. <code>pepe doctor</code> flags it if you forget.</div>
