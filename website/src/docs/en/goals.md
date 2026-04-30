---
title: Goals
description: Run an agent toward an outcome, checked by an independent reviewer, until it is actually done.
---

## Prompting vs. pursuing a goal

A prompt buys you **one turn**. The agent answers, and then *you* decide whether it is good enough, ask for a fix, and repeat. That puts you in the loop as both the approver and the quality inspector, and the work only moves while you are at the keyboard.

A **goal** buys you an **outcome**. You say what "done" means, and Pepe keeps working until an independent reviewer agrees it has been reached, or until it runs out of attempts.

The difference is *who checks*. In a normal turn the agent decides for itself that it is finished, which is exactly the assessment you cannot trust. In a goal, a **separate model call** grades the result against your criterion.

## Running one

```bash
pepe goal "OBJECTIVE" --criteria "how we know it's done" \
  [--max-attempts 3] [--judge MODEL] [--agent NAME]
```

A real example:

```bash
pepe goal "clean up the customer list in ~/data/customers.csv" \
  --criteria "no duplicate emails, and every row has a valid phone number" \
  --max-attempts 4
```

Pepe prints each attempt and the reviewer's verdict as it goes:

```
── attempt 1/4 ──
[-> read_file customers.csv]
[✓ read_file]
...
↻ reviewer: 3 rows still have an empty phone column

── attempt 2/4 ──
...
✅ reviewer: no duplicate emails remain and every row has a phone

✅ Goal met after 2 attempt(s).
```

On the dashboard, run it from any chat:

```
/goal clean up the customer list | no duplicate emails, every row has a valid phone
```

The panel above the conversation then shows the criterion, the attempt count, and the reviewer's latest verdict while it works.

## How the reviewer stays independent

The reviewer is a fresh call with a **clean context**. It never sees the working conversation, only two things: your criterion and the final result. So it grades the artifact, not the reasoning that produced it, and it cannot be talked into approving by an agent that is confident about being wrong.

By default the reviewer uses the agent's own model connection. Pass `--judge` to give it a **different** model, which is the stronger setup: an independent reviewer is more independent when it is not the same model marking its own homework.

```bash
pepe goal "..." --criteria "..." --judge gpt-5-review
```

If the reviewer's answer comes back unreadable, Pepe counts it as **not met**. Passing on an unreadable verdict would let a bad result through, which is the one thing this loop exists to prevent.

## The attempt cap

The cap is **mandatory** (3 by default, 10 at most). A criterion the agent can never satisfy must cost a bounded number of attempts, not run forever. When the cap is reached, Pepe stops, marks the goal `blocked`, and tells you what was still missing:

```
🛑 Gave up at the attempt cap. Still missing: 3 rows still have an empty phone column
```

That message is useful on its own: it is usually either a criterion that was impossible, or a real obstacle worth looking at yourself.

## Writing a criterion that works

The criterion is the whole feature. A vague one turns the reviewer into a coin flip and the loop never converges.

- **Good:** "no duplicate emails, and every row has a phone number matching `+NN NNNNN-NNNN`"
- **Bad:** "the list is clean"

Ask yourself: *could a stranger, seeing only my criterion and the result, decide yes or no without asking me anything?* If not, the reviewer cannot either. Prefer criteria that name a checkable property (a count, a format, a file that must exist, a test that must pass) over ones that describe a feeling of quality.

## Goals and tools

A goal is not a special mode: it wraps a normal turn. The agent still has all of its tools, so it can read files, query a database, or call an API while working toward the goal. Only the **final answer** of each attempt goes to the reviewer.

## What the goal loop is not

- It is **not** a scheduler. To run something on a recurring basis, see [Scheduled tasks](/en/docs/scheduled/).
- It is **not** a watcher. To be notified when a condition becomes true, see [Watches](/en/docs/watches/).

A goal ends. It either gets there or gives up, and then it is done.
