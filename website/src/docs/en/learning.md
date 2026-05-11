---
title: Learning
description: How an agent turns trusted conversations into durable memory and skills, how to see what it learned, and how to keep that knowledge tidy.
---

## Turning conversations into knowledge

An agent can turn conversations into lasting knowledge on its own, through the
"reflect" loop. It learns only from **trusted** conversations, so a client's chat with
a support bot never becomes memory.

## Who an agent learns from

Who counts as trusted is a per-bot `trainers` allowlist:

| `trainers` | What it means |
|------------|---------------|
| `["*"]` | Learns from everyone. |
| `[]` | Learns from no one. This is what a client-facing bot wants. |
| `[id1, id2]` | Learns only from those user ids, which are your ids, the trainers. |
| omitted or `null` | The default, which is everyone. |

The allowlist convention is the same everywhere in Pepe: `["*"]` is all, `[]` is
none, `[items]` is exactly those, and omitted or `null` is that field's default.

```bash
pepe gateway telegram add support --token $T --agent helper --trainers none
# a client-facing bot that never learns; your own DM bot (no --trainers) still does
```

The same allowlist is what gates the `/learn` command and per-channel model
switching. See [Channels](../channels/) for where `trainers` is configured on each
connection.

## Memory and skills, kept apart

After a trusted session the agent reviews the conversation and updates two things,
deliberately kept separate:

- **Memory** is about *you*, and it lives in `USER.md`, `MEMORY.md`, and `people.md`.
  It is kept lean, so the agent consolidates instead of piling on.
- **Skills** are about *technique*. The reviewer prefers updating a rich existing
  skill over spawning a narrow new one.

The review is a background run with its tools restricted to file and skill
management. It has no shell and no network, so it can update the workspace and
nothing else, and the live session is left untouched. It fires on `/compact`, on idle
(about 90 seconds after the last turn), and on demand with **`/learn`** (Telegram and
the console).

## Seeing what it learned: TimeLearn

TimeLearn shows what an agent has learned, on a timeline: skills (🧠) and memory
entries (📝), newest first, with source and date.

```bash
pepe timelearn assistant         # in the terminal
```

The same timeline is the **Learning** tab in the dashboard, with an agent picker. The
division of labor is simple: the generator (reflect) produces, and TimeLearn displays.

## Consolidation

The per-conversation review keeps memory lean as it goes, but each run only sees its
own session. Over many conversations, an agent's memory can still accumulate overlap.

**Consolidation** is a standalone housekeeping pass. The agent re-reads its *whole*
standing memory and skills, with no conversation in front of it, and tidies them. It
merges duplicates, drops stale or contradicted lines, and combines overlapping
skills, without losing any durable fact. It uses the same restricted, file-only
reviewer.

```bash
pepe learn consolidate assistant              # run a pass now
pepe learn auto assistant                     # schedule it nightly (default 0 3 * * *)
pepe learn auto assistant --at "0 */12 * * *" # or a custom schedule
pepe learn auto assistant --off               # stop the schedule
pepe learn status                             # which agents consolidate on a schedule
```

In the dashboard, the **Learning** tab has a **Consolidate now** button and a
**Nightly** toggle. The nightly schedule is a managed entry on the
[Scheduled tasks](../scheduled/) page (a `consolidate` job), and each pass is recorded
like any other run, so you can replay it in the dashboard's Traces. See
[Dashboard](../dashboard/).
