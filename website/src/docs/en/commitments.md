---
title: Commitments
description: Follow-ups noticed automatically from conversation - a reminder the user asked for, or a promise your agent made.
---

## Commitments

A commitment is different from every other automation in Pepe: it is not something you set up. It is noticed on its own, after a turn, from what was actually said - the user asking to be reminded of something, or the agent itself promising to check on something and get back to them. Turn it on per agent (`commitments`, off by default) and give that agent a `utility_model` - without both, nothing is extracted, and a promise stays just words.

### Two kinds of follow-up, delivered two different ways

This is the detail worth understanding before turning it on, because the two cases are not handled the same way:

- **A user's own reminder** ("me lembra de mandar o relatório sexta") is satisfied by a message at the right time - the same thing a [watch](../watches/) already does. If your agent has the `watch` tool, it's still worth having it reach for that directly in the moment; commitments exist as the net for when it doesn't.
- **The agent's own promise** ("let me check the deploy and I'll tell you tomorrow") is *not* satisfied by a reminder saying the promise was made. When it comes due, Pepe re-runs that session with one instruction: actually do the thing, then reply with what you found. The message that goes out is a real answer, not a template - so a promise never quietly resolves into "reminder: I said I'd check that."

### Confidence, and what happens when it's uncertain

A cheap model call reads the last exchange and decides whether there's a genuine commitment, with a confidence score. High enough, and a resolved due time, and it's scheduled outright - no extra step, matching "notice it without being asked twice." Below that, or when the due time couldn't be resolved from what was said (a vague "sometime soon" isn't a date), it lands **awaiting your ok**: you get asked directly, once, rather than it silently tracking something nobody actually asked for.

### Managing them from chat

The agent's `commitment` tool has three actions: `list` (what's currently tracked), `confirm id: <id>` (promote an awaiting one - pass `due_when` too if the date never resolved), and `cancel id: <id>`.

### Do it in the dashboard

Open the **Commitments** page under `pepe serve` to see everything tracked, grouped into awaiting your ok, scheduled, and delivered. Confirm or cancel directly from there.

<div class="note"><strong>No server to run, just a local file.</strong> Commitments live in a small embedded SQLite file alongside <code>config.json</code>, not a database you need to install or manage. They're fired by the same kind of in-process timer that drives watches and scheduled tasks, which only ticks while a long-lived surface (<code>pepe serve</code>, a gateway, or an interactive session) is up. Upgrading from an older Pepe that kept commitments in <code>config.json</code> itself? Run <code>mix pepe config migrate-commitments</code> once to bring the old ones over. <code>pepe doctor</code> flags it if you forget.</div>
