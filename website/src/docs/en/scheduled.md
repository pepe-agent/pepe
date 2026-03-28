---
title: Scheduled work
description: Run agents on a recurring schedule and set durable "notify me when X happens" watches, driven by an in-app minute ticker with no OS crontab and no database.
---

Pepe can do work while you are away. There are two shapes of this, and they solve different problems:

1. **Recurring tasks** (crons). A task runs an agent on a fixed schedule, over and over. "Every weekday at 9am, summarize the overnight alerts." It keeps firing until you disable or remove it.
2. **Watches** ("notify me when X"). A watch keeps checking a condition and messages you exactly once when it becomes true. "Tell me when the deploy finishes." Then it stops on its own.

Both run inside Pepe itself. A small timer ticks every 30 seconds and fires whatever is due. There is no OS crontab, no external scheduler, and no database. Everything lives in your `~/.pepe/config.json`, and task run history is written to plain log files. The timer only runs while a long-lived surface is up, meaning `pepe serve` or a `pepe gateway`. A one-shot command like `pepe run` never starts it, so it can never fire jobs on its own.

Each capability here can be driven three ways: the `pepe` command line, the web dashboard (open it with `pepe serve`), and by chat, in plain language, when an agent holds the matching management tool.

## Recurring tasks

A task is a self-contained prompt, a schedule, a timezone, and a place to deliver the result. When it fires, Pepe runs the agent on that prompt in a **fresh session with no chat history**. Nothing from any earlier conversation is carried in, so the prompt has to say everything the run needs (what to do, which data to look at, the time window).

### Create a task from the CLI

```bash
pepe cron add \
  --name "morning-brief" \
  --agent assistant \
  --prompt "Summarize any error-level log lines from the last 24 hours and list the top 3 issues." \
  --schedule "0 9 * * 1-5" \
  --timezone "America/Sao_Paulo" \
  --deliver "telegram:123456789"
```

Only `--name`, `--prompt`, and `--schedule` are required. The rest fall back to sensible defaults:

| Flag | What it does | Default |
| --- | --- | --- |
| `--agent` | Which agent runs the prompt | Your default agent |
| `--timezone` | IANA timezone the schedule is read in | The configured default (see below) |
| `--model` | Run this task with a specific model connection | The agent's own model |
| `--deliver` | Where the result goes | `none` (recorded, sent nowhere) |

The full command set:

```bash
pepe cron list                 # every task, with its next run time
pepe cron add ...              # create a task (see above)
pepe cron run morning-brief    # force it now, print the result (a dry run)
pepe cron disable morning-brief
pepe cron enable morning-brief
pepe cron remove morning-brief
pepe cron logs morning-brief   # recent run history
```

Each task gets a readable id derived from its name (`morning-brief`). If that id is taken, Pepe appends a number (`morning-brief-2`).

### Do it in the dashboard

Run `pepe serve` and open the **Scheduled** page. It lists every task with its next run time, and gives you the same actions as buttons: create a new task with a form, force a run now, enable or disable, edit, remove, and open a task's run history in place. When you type a task's schedule, the dashboard can turn a plain phrase like "every weekday at 9:30" into the matching cron expression for you, using a configured model, and it validates the result before saving.

### Schedule expressions and timezones

The schedule is a standard 5-field cron expression: `minute hour day-of-month month day-of-week`.

```
0 9 * * 1-5     # 09:00, Monday through Friday
*/15 * * * *    # every 15 minutes
0 0 1 * *       # midnight on the 1st of each month
30 8 * * *      # 08:30 every day
```

A task carries its own **named timezone**, not a fixed UTC offset. This matters because "9am local" drifts against UTC twice a year across daylight saving. Pepe stores the expression plus a zone name like `America/Sao_Paulo` or `Europe/Berlin`, and evaluates the schedule in that zone. Around a daylight-saving change it does the sensible thing: it skips forward through a spring gap and picks the later side of an autumn overlap, so a job never silently double-fires or vanishes.

Set your default zone once during `pepe setup`. Tasks that do not name their own zone use it. If nothing is configured, the fallback is UTC.

<div class="note"><strong>Describe the schedule in words.</strong> A cron expression is easy to get wrong by hand. Both the dashboard form and a chat agent can turn a phrase like "every weekday at 9:30" into the matching expression for you. Every generated expression is validated before it is saved, so an invalid one is never stored.</div>

### Where the result goes

The `deliver` target decides what happens with a run's output:

- `telegram:<chat_id>` sends it to that Telegram chat. The message is prefixed with the task name so a chat receiving several tasks can tell them apart.
- `none` sends it nowhere. The run still executes and is still recorded in history. Good for tasks whose only job is a side effect (writing a file, calling a tool).
- Anything else (including `log`) writes the output to the application log.

Regardless of the target, every run is appended to that task's own history file, so you can always read back what happened.

### The minute ticker and catch-up

The scheduler ticks every 30 seconds (sub-minute on purpose, so a little clock drift never makes it miss a minute). On each tick it looks at every enabled task and fires the ones whose schedule matches the current minute in that task's timezone. A per-task guard makes sure a job fires **at most once per minute** even though the tick is faster than that.

If the process was down at the moment a task was supposed to fire, Pepe does a bounded **catch-up** on recovery. When it comes back and notices a scheduled slot passed without a run, it fires that job once, as long as it is still within a grace window (half the job's period, clamped between 2 minutes and 2 hours). The catch-up is anchored to the missed slot, so one recovery never double-fires. A job that has been down far longer than its grace window is simply picked up at its next normal slot instead of replaying a stale one.

### Run history

Every fire, whether from the timer, a forced `pepe cron run`, a dashboard button, or a chat, appends one line to a per-task history file (`<PEPE_HOME>/data/cron_logs/<id>.jsonl`). Each line records the timestamp, the source, whether it succeeded, and the (clipped) output.

```bash
pepe cron logs morning-brief
```

```
✦ Runs of morning-brief

✅ 2026-07-06 09:00 · scheduler
   3 issues overnight. Top: DB connection pool exhausted (x42), ...

⚠️ 2026-07-05 09:00 · scheduler
   error: :timeout
```

The `source` on each line is one of `scheduler` (the timer fired it), `manual` (you forced it from the CLI or the dashboard), or `agent` (a chat forced it).

### Do it by chat

An agent can create and manage its own scheduled tasks during a conversation, in the CLI chat or any connected channel, if it has the `schedule_task` tool in its toolset. Ask in plain language:

> Every weekday at 8:30 my time, check the status page and message me here if anything is degraded.

The agent knows the current local time (its system prompt is grounded with it), so "tomorrow at 8:30" resolves to the right slot instead of drifting to UTC. It writes the full self-contained prompt for you, picks the cron expression, and by default delivers the result back to the same chat you asked from.

The `schedule_task` tool supports the same actions as the CLI: `create`, `list`, `run` (force now to preview), `enable`, `disable`, `remove`, and `history`.

#### The double opt-in gate

Creating scheduled work from chat is deliberately guarded twice, because a task runs unattended later:

1. **The tool has to be granted to the agent.** An agent can only schedule anything if `schedule_task` is in its allowlist. Agents without it simply cannot.
2. **Each create still asks you.** `schedule_task` is a gated tool, so unless it has been pre-approved, the runtime asks you to authorize the specific call before it takes effect. Each surface renders that prompt in its own native way (inline buttons on Telegram, an arrow-key menu in the terminal). You can answer just this once, for the rest of the session, always (remembered on the agent), or deny.

So a task never appears behind your back: the capability is opt-in, and each concrete task is opt-in too.

## Watches

A watch answers a different question: not "do this on a clock" but "keep an eye on something and tell me the moment it happens." A watch re-checks a condition on a timer and notifies you **once** when it becomes true, then stops. It is durable: it survives a restart and the closing of the session that created it, and it always replies on the channel it was created from.

### Probe versus agent triggers

The cheap part of a watch is the **trigger**, which runs on every interval. Only when the trigger fires does the (possibly expensive) notification run, once. There are two kinds of trigger:

- A **probe** runs a shell command and costs no tokens per check. Success is exit code 0 by default, or you can require a string to appear in the command's output. Use a probe whenever the condition is scriptable (a URL is reachable, a job wrote a file, a log contains a line).
- An **agent** trigger re-asks the agent a yes/no question each interval, one model call per check. Use it only when deciding whether the condition is met needs real judgement.

Because agent checks cost tokens, their minimum interval is higher: 300 seconds for agent triggers, 30 seconds for probes. The default interval is 120 seconds.

### What it sends when it fires

When the trigger finally passes, a watch delivers a message. That message is either a fixed **template** (a piece of text you set up front, no model call), or **composed by the agent** at fire time (one model call, once) so it can include fresh detail like a summary of what actually happened.

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

A watch records its **origin**, the channel and conversation it was created from, at creation time. When it fires it delivers back there, even after a restart, whether that is a Telegram chat, a connected terminal or WebSocket session, or the application log. If the watch was created over the stateless HTTP API (which has no conversation to message back), it falls back to the log.

Two guarantees make this reliable:

- **At most once.** The watch's new state (usually "done") is saved to disk *before* delivery is attempted. If the process crashes between firing and delivering, it will not re-check and fire a second time. Only the delivery is retried.
- **Deliver when reachable.** If a watch fires while its channel is offline (a terminal session that has disconnected, for example), the message is held and re-sent on every tick until it lands. You get the notification when you come back, without the watch re-checking.

A watch moves through a small set of states over its life: `pending` (still watching), `paused`, `done` (fired and delivered), `expired` (ran out of its check budget), or `cancelled`.

<div class="note"><strong>No database, no crontab.</strong> Tasks and watches are plain records in <code>~/.pepe/config.json</code>, and task run history is one JSONL file per task under <code>&lt;PEPE_HOME&gt;/data/cron_logs/</code>. There is nothing else to install or keep running. The whole scheduler is an in-process timer that starts when you run <code>pepe serve</code> or a gateway, and stops when you stop them.</div>
