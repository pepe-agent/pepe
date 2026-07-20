# Board (durable task cards)

A durable, resumable queue of work items with dependencies between them, for handing
off multi-step or long-running work between agents and humans. Not a sales/CRM tool: a
card is a work item, not a contact or a lead. Manage it with the `board` tool.

A card moves through a status pipeline: `todo -> ready -> running -> done | blocked ->
archived`. It never silently re-fires: a stalled or crashed claim always lands in
`blocked`, waiting for an explicit `unblock`, so a broken card can't burn model calls
unattended with no trace.

## Create a board (`board create_board`)

```
board create_board
  name: "Engineering"
  project: "acme"          (optional, omit for the root/default project)
  auto_dispatch: true       (a ready card with an assignee fires on its own; the
                              default, false, means only an explicit claim starts one)
  claim_timeout_s: 1800     (a running claim older than this is treated as stalled
                              and blocked; omit for the default, 0 = never)
```

## Create a card (`board create_card`)

```
board create_card
  board_id: "acme/eng"
  title: "Fix the checkout timeout"
  body: "Everything the assignee needs: this is all it gets, no chat memory."
  assignee: "acme/support"          (an agent handle; required for auto_dispatch)
  priority: 5                       (higher = dispatched first among ready cards)
  depends_on: ["c_ab12", "c_cd34"]  (same-board card ids that must be `done` first)
  auto_dispatch: false              (optional, overrides the board's own setting
                                      for just this card; omit to inherit it)
```

A card's own `auto_dispatch` beats its board's, in either direction: a card can be
forced to fire on its own inside an otherwise manual board, or forced to stay manual on
an otherwise automatic one. A manual `claim` always works regardless of any of this:
`auto_dispatch` (at either level) only decides whether the scheduler's own tick fires
the card without being asked. `board set_auto_dispatch card_id: <id> value:
"on"|"off"|"inherit"` changes it on an existing card.

## Working a card you were dispatched to

If your session was started by a board (an `auto_dispatch` board claiming and running
you), you do **not** need to pass a `card_id` to `complete`/`block`/`comment`: it's
inferred from your own session automatically. From anywhere else (a human's chat, one
agent managing another's board), pass `card_id` explicitly.

- `board complete text: "what you found/did"` when the work is done.
- `board block text: "why: waiting on X, needs a human decision, ..."` when you can't
  finish it. Always leave a reason; a card blocked with no reason is a dead end for
  whoever looks at it next.
- `board comment text: "..."` to leave a note without changing status, useful for
  progress updates on something that will take a while.

**If you were assigned to a board with `auto_dispatch: true`, you need `board` in your
own `auto_approve` list.** A dispatched session has no human attached to approve
anything, so without it every `complete`/`block`/`comment` call is silently denied and
the card just sits until the board's `claim_timeout_s` blocks it. Tell the user this
when helping set one up.

## Other actions

- `list_boards` / `list_cards board_id: <id> [status: <status>]`.
- `show_card card_id: <id>`: full detail plus recent activity.
- `link card_id: <id> depends_on_id: <id>`: add a dependency (rejected if it isn't on
  the same board, or would create a cycle).
- `force_ready card_id: <id>`: `todo -> ready`, skipping the dependency check.
- `set_auto_dispatch card_id: <id> value: "on"|"off"|"inherit"`: override (or clear)
  whether this one card fires on its own, regardless of its board's setting.
- `claim card_id: <id>`: `ready -> running`, works whether or not the board
  auto-dispatches.
- `unblock card_id: <id>`: `blocked -> ready`, clearing the claim.
- `archive card_id: <id>`: refuses a `running` card (that's the dashboard/CLI's job,
  which can force it; ask the user to do that there if a card genuinely needs to be
  cut short).

## Notes

- Boards are project-scoped, same as agents and models: a board's id is
  `<project>/<name>` (or just `<name>` in the root/default project).
- Auto-dispatch only ever fires a card that is `ready` **and** has an `assignee` set;
  an unassigned ready card just waits to be claimed manually.
- The scheduler ticks about every 30 seconds, so promotion (`todo -> ready` once
  dependencies finish) and auto-dispatch aren't instant.
