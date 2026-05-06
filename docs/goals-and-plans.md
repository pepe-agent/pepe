# Goals and plans

Two tools give an agent working state for a longer task, so it stays coherent across many
turns instead of reacting one message at a time. Both are **per-conversation**: they live
with the session (in the disposable store), and their tool results show in the chat and in
[Traces](traces.md). They are opt-in, add `goal` and/or `update_plan` to an agent's tools.

## Goal: the north star

A **goal** is a persistent objective plus a status. The agent sets one at the start of a
non-trivial task, re-reads it to stay oriented, and marks it done (or blocked) at the end.

The `goal` tool actions:

- `set` - an `objective` (what it is trying to achieve), and an optional advisory
  `budget_tokens` target to keep the effort proportionate.
- `status` - mark `active`, `paused`, `blocked` or `complete`, with an optional `note`.
  `blocked` is how the agent signals it is stuck and needs the user; `complete` when the
  objective is met.
- `show` - return the current goal.
- `clear` - drop it.

The objective and status persist across turns (and a restart), so a long or autonomous
run does not drift off what it set out to do.

> The `budget_tokens` is an **advisory target** the agent is told about, not a hard cap.
> Hard spend limits are the per-company monthly cap in [Usage & billing](billing.md).

## Plan: the live checklist

`update_plan` maintains an ordered checklist of steps, each `pending`, `in_progress`, or
`done`. Every call passes the **full** list and replaces the previous one, so there is
always one coherent plan. The rendered checklist comes back on each update:

```
Plan (1/3 done):
[x] read the failing test
[~] find the root cause
[ ] write the fix
```

The agent keeps one step `in_progress` at a time and updates as the work evolves; an empty
`steps` list clears the plan. Use it for multi-step work so progress stays visible; skip it
for a trivial one-step request.

## Enabling them

```bash
mix pepe agent add worker --prompt "..." --tools bash,read_file,edit_file,goal,update_plan
# or add them to an existing agent's tool list in the dashboard (Agents tab)
```

Both appear in `mix pepe tools` once enabled.

## Seeing the current goal and plan

In the dashboard, the **Chat** tab shows a slim **focus panel** under the header of
the selected conversation: the goal (objective + a status badge) and the plan checklist,
updated as the agent works. It is also visible in the flow itself, each `goal`/`update_plan`
call and its result show in the conversation and in [Traces](traces.md).

---

[Back to the docs index](../README.md#documentation)
