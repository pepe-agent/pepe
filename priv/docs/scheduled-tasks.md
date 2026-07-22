# Scheduled tasks (cron)

Run an agent on a recurring schedule. A task fires in a **fresh session with no chat
memory**, so its prompt must be self-contained (bake in the context, the data source,
the window). Manage tasks with the `schedule_task` tool.

## Create a task (`schedule_task`)

```
schedule_task create
  name: "Daily XML check"
  prompt: "Check the 06:00 XML load and report anything abnormal. ..."   (self-contained)
  schedule: "0 8 * * *"          (standard 5-field cron: 08:00 every day)
  timezone: "America/Sao_Paulo"  (any IANA name; omit for the configured default)
  model: <optional model override>
  deliver: "telegram:<chat_id>"  (or "none" to just keep the run history)
```

When created from a chat, `deliver` defaults to that same chat. Confirm the details
(what, when, timezone, where to report) with the user first.

## Other actions

- `list` - all tasks with their next run.
- `run id: <id>` - force a task now to preview it.
- `enable` / `disable` / `remove id: <id>`.
- `history id: <id>` - recent runs.

## Notes

- Schedule is a standard 5-field cron expression. Timezone is any IANA name - never
  hard-code it; use what the user asked (e.g. "6am German time" -> `Europe/Berlin`).
- Tasks only fire while a long-running surface is up (`mix pepe serve` / `gateway`).
- Each due task runs in its own process, so many can fire at once without blocking.

## A task does not run on top of itself

If a task's previous run is still going when its next slot comes round, that slot is
**skipped**, and the skip is written to its run history. A task here is an agent turn:
it costs a model call, it has side effects, and every run of it shares one agent
workspace, so piling up would bill twice, deliver twice, and let two runs write over
each other.

If the user asks why a task seems to have stopped running, look at its history
(`logs`): a run of skips means the job takes longer than its own schedule allows. Tell
them so, and offer the three real fixes: a longer interval, less work per run, or
`overlap: true` if running it on top of itself is genuinely what they want.

## Flows aren't scheduled this way

A **flow** (a proven, identical tool-call sequence promoted from real traces - see the
`docs` tool for `flows` if it's in your index) can also run on a schedule, but not
through `schedule_task`: that's an operator action (`mix pepe flow schedule`), not
something you create from chat. If a user asks to "schedule my flow," tell them that's
set up by an operator on the CLI, not something you can do here - don't offer to create
it as a regular scheduled task instead, since a flow replays exact tool calls with no
model in the loop, which `schedule_task`'s agent-turn model does not do.
