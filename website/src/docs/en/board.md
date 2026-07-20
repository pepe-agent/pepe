---
title: Board
description: Durable task cards with dependencies, for handing off work between agents and humans.
---

## What it is

A board is a durable, resumable queue of work items: **not** a sales/CRM pipeline. A
card is a work item, not a contact or a lead. Where a scheduled task fires the same
prompt on a repeating clock, a board card is a one-off piece of work that moves through
a status pipeline, can depend on other cards finishing first, and survives a crash or a
restart instead of just being lost.

```
todo → ready → running → done | blocked → archived
```

A card is promoted from `todo` to `ready` once every card it depends on is `done`. From
`ready` it's **claimed** (by a human, an agent, or automatically) and moves to
`running`. It ends at `done`, or at `blocked` with a reason if something stopped it,
including a claim that stalled or a run that ended without ever saying it was finished.
A blocked card always needs an explicit `unblock` before it can run again: nothing here
silently retries on its own, because a card is a real agent turn, not a script.

### Create a board from the CLI

```bash
pepe board add --name "Engineering" --project acme
```

`--auto-dispatch` turns on unattended firing: a `ready` card with an assignee starts on
its own once the board notices it, instead of waiting for someone to claim it. It's off
by default: see the security note below before turning it on. `--claim-timeout-s`
controls how long a claim may run before it's treated as stalled and blocked (default
1800; `0` means never).

```bash
pepe board card add acme/eng \
  --title "Fix the checkout timeout" \
  --body "Everything the assignee needs: this is all it gets, no chat memory." \
  --assignee acme/support \
  --priority 5 \
  --depends-on c_ab12,c_cd34
```

A card can override its board's own `auto_dispatch`, in either direction: `--auto-
dispatch` / `--no-auto-dispatch` on `card add`, or `pepe board card auto-dispatch ID
on|off|inherit` on an existing one. A manual claim always works regardless of any of
this: it only decides whether the scheduler's own tick fires the card unasked.

The full command set:

```bash
pepe board list                          # every board
pepe board add --name N [...]            # create a board
pepe board remove ID [--force]           # remove (--force drops its cards too)

pepe board card list BOARD_ID [--status S]
pepe board card show ID
pepe board card add BOARD_ID --title T [...] [--auto-dispatch|--no-auto-dispatch]
pepe board card link ID DEP_ID           # add a dependency
pepe board card force-ready ID           # skip the dependency check
pepe board card auto-dispatch ID on|off|inherit  # override this card's own dispatch
pepe board card claim ID [--as NAME]
pepe board card complete ID [--text NOTE]
pepe board card block ID --text REASON
pepe board card unblock ID
pepe board card comment ID --text NOTE   # a note, no status change
pepe board card archive ID [--force]     # --force also archives a running card
pepe board card unarchive ID
```

### Do it in the dashboard

Run `pepe serve` and open the **Board** page. Pick a board (or create one) to see its
cards grouped into columns by status. From there you can create a card, claim a ready
one, unblock a blocked one, or archive one, including force-archiving something still
`running`, which is the one action deliberately **not** available to an agent (see
below). The page updates live as cards change, whether that change came from the
dashboard, the CLI, or an agent working the board.

### Do it by chat

An agent manages boards and cards with the `board` tool, if it's in its toolset:

> Create a board called "Support escalations" and put a card on it for the login bug
> Sarah reported, assigned to the on-call agent.

When an agent is dispatched to work a card itself (an `auto_dispatch` board claiming and
running its assignee), it doesn't need to pass a card id to `complete`, `block`, or
`comment`: Pepe infers it from that session automatically.

<div class="note"><strong>An auto-dispatch assignee needs <code>auto_approve</code> for <code>board</code>.</strong> A card dispatched by an auto-dispatch board has no human attached to approve anything, the same as a scheduled task's unattended run. Without <code>board</code> in the assignee agent's <code>auto_approve</code> list, every <code>complete</code>/<code>block</code>/<code>comment</code> call it makes is silently denied, and the card just sits until the board's claim timeout blocks it.</div>

## Dependencies and cycles

`depends_on` names other cards on the **same board** that must be `done` first: a
cross-board dependency, an unknown id, or anything that would create a cycle is
rejected when you try to add it. An `archived` card never satisfies a dependency, only
`done` does: if something a card is waiting on gets cancelled, the waiting card stays
visibly stuck in `todo` rather than silently promoting past an abandoned decision.

## Claims are race-free

Two callers (a human clicking "Claim" and an agent's tool call, or two auto-dispatch
ticks) can never both win a claim on the same card. The first one through wins; the
other gets a clean "not ready" error. This holds without any extra locking step on your
part: it's just how `claim` is built.

## Auto-dispatch and the claim timeout

With `auto_dispatch` off (the default), a `ready` card just waits: nothing fires it but
an explicit `claim`, from the dashboard, the CLI, or an agent. With it on, the board's
own ticker (about every 30 seconds) claims and dispatches any `ready` card that has an
assignee, running that agent in a fresh session built around the card. An unassigned
`ready` card never auto-fires either way.

Any single card can override its board's own setting: force one card to fire on its
own inside an otherwise manual board, or force one card to stay manual on an otherwise
automatic board. Set it when creating the card, change it later on the dashboard (a
small select on the card itself), the CLI (`card auto-dispatch ID on|off|inherit`), or
by chat (`board set_auto_dispatch`).

`claim_timeout_s` is the safety net for a dispatched run that goes quiet: if a claim
outlives it, the card is blocked with "claim timed out" rather than left claimed
forever. The same thing happens if the dispatched session ends (normally or by
crashing) without ever calling `complete` or `block`: that's treated as a protocol
violation, not silently retried.
