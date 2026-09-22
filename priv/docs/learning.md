# Learning - turning conversations into memory and skills

You can improve yourself as you go. "Learning" here is **not** model fine-tuning -
it's you reviewing a conversation and writing what mattered into your own workspace
files, so a future session starts smarter. Two kinds of knowledge, kept separate:

- **Memory** - about *the user*: preferences, persona, personal facts, how they want
  you to work. Goes into `USER.md`, `MEMORY.md`, or `people.md` in your workspace
  (`~/.pepe/agents/<you>/`). Kept lean - you consolidate instead of piling on.
- **Skills** - about *technique*: a reusable fix, workaround, or a correction to your
  style/workflow. Goes into `skills/<name>.md`, first line a one-line "use when ..."
  summary. Prefer editing an existing skill over spawning a narrow new one.

Use the `memory_search` tool to find one thing in your own memory instead of reading
a whole file - a plain case-insensitive match over `MEMORY.md`/`USER.md`/`people.md`,
returning each matching entry tagged with the file it came from.

## The reflect loop (how it happens on its own)

After a conversation you get a background **review**: a restricted copy of you runs
over the transcript with tools cut down to file/skill management only (`read_file`,
`write_file`, `edit_file`, `list_dir`, `skill`, `skill_manage`) - no shell, no network, and
no human permission prompt, so the review can update your workspace but nothing else. The
live session is untouched. It fires three ways:

- on **`/compact`** - reviewed before the history is squashed, while detail is fresh.
- on **idle** - about 90 seconds after the last turn.
- on demand with **`/learn`** (Telegram + console).

## Who you're allowed to learn from (`trainers`)

You don't learn from everyone - a client's chat must never become your memory. Each
channel-bound bot carries a `trainers` allowlist that gates it per conversation:
`["*"]` or omitted = learns from everyone, `[]` = learns from no one (a client-facing
bot), `[id1, id2]` = only those user ids. Owner console and API conversations learn by
default. See **channels** for how a bot's `trainers` is set.

## Reviewing and steering what you learned

- **`mix pepe timelearn <you>`** shows your learning on a timeline - skills (🧠) and
  memory entries (📝), newest first, with source and date. There's also a **Learn**
  tab in the dashboard. (The reflect loop produces; TimeLearn just displays.)
- **`remember`** on the `manage_agent` tool appends a durable fact straight into a
  target's `MEMORY.md` - an explicit way to train an agent without waiting for a
  review (only within your admin scope - see **agents**).

## Consolidation (housekeeping)

Each review only sees its own session, so over many conversations memory can still
accumulate overlap. **Consolidation** is a standalone pass with no transcript: the
same restricted, file-only reviewer re-reads your *whole* standing memory and skills
and tidies them - merging duplicates, dropping stale or contradicted lines, combining
overlapping skills - without losing a durable fact.

```bash
mix pepe learn consolidate <you>          # run a pass now
mix pepe learn auto <you>                  # schedule it nightly (default 0 3 * * *)
mix pepe learn auto <you> --at "0 */12 * * *"   # or a custom schedule
mix pepe learn auto <you> --off            # stop the schedule
mix pepe learn status                      # which agents consolidate on a schedule
```

The nightly job is a managed `consolidate` entry on the scheduled-tasks page, and each
run is recorded like any other run.

## Writing skills: `skill_manage`

Skills are written through the `skill_manage` tool (actions `create`, `edit`, `patch`,
`delete`, `write_file`, `remove_file`), not with the file tools. Every change is scanned,
size-limited, snapshotted and recorded (who, what, before and after), so a person can undo
it with `mix pepe skill undo ID`. Rules that apply to you:

- In a conversation with a person present, the call goes through the normal permission
  prompt, and what you create is **theirs** afterwards.
- In the background review and the curator, nobody is asked, so the rules are tighter: you
  may only change skills an **agent wrote in the background** (or a person handed over with
  `mix pepe skill adopt`). Skills the person wrote, installed skills, bundled skills and
  pinned skills are refused - suggest the change in your summary instead. You must open a
  skill with `skill` before you patch or overwrite it. Prefer `patch` on the skill you
  used, then on a broader "umbrella" skill, then a support file (`references/`,
  `templates/`, `scripts/`), and only then a new class-level skill.
- A transcript that took in outside content (a fetched page, a search result, an
  attachment) is reviewed for memory only, never for skills.

## The skill curator

Unused skills an agent wrote in the background are tidied by the **curator**: after
`stale_after_days` (default 14) without being used, opened or changed a skill is marked
stale, after `archive_after_days` (default 30) it is archived (moved aside, never
deleted; `mix pepe skill restore NAME` brings it back). It runs on its own about weekly,
only when nothing has been said in any conversation for a couple of hours, takes a
snapshot of the whole skills directory first, and writes a report. An optional model pass
(`consolidate`, off by default) merges overlapping skills into broader ones through
`skill_manage`. Skills a person wrote, installed and pinned skills are never touched.

A person can look after it from chat with the `skill_curator` tool (`status`, `usage`,
`run` with `dry_run`, `pause`/`resume`, `settings`, `adopt`/`release`, `pin`/`unpin`,
`restore`, `log`, `undo`), from `mix pepe skill curator ...`, from the Learning page of
the dashboard, or from `mix pepe setup` (Skills). Prefer a dry run first when asked to
"clean up my skills", and say what it found before running it for real.
