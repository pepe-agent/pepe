---
title: Scheduled tasks
description: Run agents on recurring cron schedules.
---

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

Run `pepe serve` and open the **Scheduled** page. It lists every task with its next run time, and gives you the same actions as buttons: create a new task with a form, force a run now, enable or disable, edit, remove, and open a task's run history in place. The create form covers everything the CLI does: the agent, the prompt, the schedule, the timezone, the model, and where to deliver the result, including a "Don't send anywhere" option. When you type a task's schedule, the dashboard can turn a plain phrase like "every weekday at 9:30" into the matching cron expression for you, using a configured model, and it validates the result before saving.

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

The ticker lives inside the application process, so it only runs while `pepe serve` or `pepe gateway` is up, and never during a one-shot command. Each due task runs in its own process, so several tasks falling on the same minute fire concurrently and one slow task never blocks another. The task definitions themselves are stored in `~/.pepe/config.json`, under `"crons"`.

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
