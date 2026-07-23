---
title: Flows
description: Promote a proven, repeated tool-call sequence into a script that replays without calling the model.
---

## Why this exists

An agent re-decides everything from scratch, every turn - even a task it has already done the exact same way three times in a row. That is worth paying for the first few times, while the agent is figuring out what to do. It stops being worth paying for once the sequence is reliable: the model call is pure overhead at that point, and it is one more place a run can go differently than last time for no reason.

A **flow** is a proven [trace](../traces/) (or several) promoted into a fixed script: the exact tool calls, in order, with the exact same arguments, replayed with no model call at all. It only ever repeats what already happened, argument for argument - it does not generate new code, and it does not guess at which parts of a call are "the same" and which vary.

## Promoting a flow

Look at a few recent runs that did the same thing the same way:

```bash
pepe traces --project acme
```

Pick two or more that made the identical tool calls, in the same order, with the same arguments, and promote them:

```bash
pepe flow promote weekly-digest --agent assistant --from 1784591017504516,1784591109332811
```

Pepe checks that every trace you named really did make the exact same sequence before saving anything. If they do not match - a different argument, a different order, an extra step in one of them - the promotion is refused, with a message telling you so, instead of guessing at what you meant:

```
✗ could not promote: those traces didn't make the exact same tool calls, in the same order,
  with the same arguments - flows only replay identical sequences
```

That refusal is deliberate. Auto-inferring "this part varies, that part doesn't" from a handful of examples is the one part of this idea that is genuinely risky - get it wrong and a flow silently does something none of the traces it came from ever did. A flow stays exact-replay-only; picking traces that truly are identical is on you, the same review a person would do before trusting a script to run unattended.

Promotion also refuses a trace that is not genuinely "proven," even if the sequence matches: one that contains a call the agent's own permission gate denied, a step that actually failed, or arguments too long to have been recorded in full (`Pepe.Trace` clips very long ones for storage) - none of that is a call you actually watched succeed. It also refuses traces that were not all made by the agent you are promoting for, since a replayed step's relative paths resolve inside *that* agent's own workspace.

## Managing flows

```bash
pepe flow list --agent assistant                 # every flow for that agent
pepe flow show assistant weekly-digest            # the exact steps it replays
pepe flow run assistant weekly-digest             # replay it now
pepe flow remove assistant weekly-digest
```

Promoting again under the same name refuses unless you pass `--overwrite`, so a fresh promotion never silently replaces an existing flow.

## Running on a schedule

A flow becomes a recurring job the same way a prompt does - through cron, just with no prompt and no model call:

```bash
pepe flow schedule assistant weekly-digest --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

This creates a scheduled task (see [Scheduled tasks](../scheduled/)) of kind `"flow"` instead of `"prompt"`. Everything about how it fires, what happens if the previous run is still going, and where its run history lives is the same as any other scheduled task.

<div class="note"><strong>Nobody is watching a flow run.</strong> A flow triggers from a timer, not a chat, so there is no one there to approve a risky step in the moment. A flow only runs a step whose tool is already in the agent's own <code>auto_approve</code> - the same rule that already governs any other unattended surface (a webhook, an API token). A step that is not pre-approved, or a step that actually fails when replayed (a missing file, a network hiccup, bad arguments), stops the whole flow right there rather than skip it or plough on - the run history says exactly which step and why.</div>

Every flow run still writes a normal [trace](../traces/), so a scheduled flow's history is inspectable the same way any other run's is.
