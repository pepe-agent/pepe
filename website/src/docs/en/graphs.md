---
title: Graphs
description: Nodes, edges, and shared state that survives across separate model calls, with a verifier that can send the flow back to an earlier step for a real revise loop.
---

## Why this exists

A normal conversation is one agent, one loop, deciding what to do next call by call. That covers almost everything. It stops being enough the moment a job has real *structure*: a draft that a second pass should genuinely be able to reject and send back, not just retry blind; a step that has to wait on a person before continuing; a few things worth checking at once before deciding what's next.

A **graph** is a named workflow of nodes and edges, with state that survives across separate model calls - something none of Pepe's other automation covers. A [flow](../flows/) replays an exact, already-proven sequence of tool calls with no model call at all - it's for a job you've done the same way enough times that it no longer needs deciding. [Delegation](../delegation/) fans a task out to read-only workers that don't share state with each other and can't act. A graph is for the job in between: genuinely multi-step, with branching that depends on what an actual review found, still calling a model at each step.

## Node types

There's no new language to learn beyond a single `{{key}}` substitution in a node's text. A graph has five kinds of node:

- **agent** - calls a model with a rendered prompt. Its reply becomes available to every later node as `{{id}}`. `next` names the following node; leave it out to end the graph there.
- **verifier** - the same kind of call, but its reply has to end on a line containing exactly one word from a fixed set of verdicts (`{"pass": "publish", "fail": "draft"}`, for instance). That word decides where the flow goes next - and the target can be an *earlier* node, which is the real revise loop this exists for: the earlier node sees the verifier's critique the next time it runs, via `{{that_verifier_id}}`.
- **human** - no model call at all. The run pauses and waits; someone's answer, whenever it comes, becomes that node's value for everything downstream.
- **parallel** - fans a list of tasks out to read-only workers, the same restrictions as [delegation](../delegation/): they can look things up, not act. The combined answer becomes the node's value.
- **tool** - calls one specific tool directly, gated the same way any tool call is, and only ever a tool the graph's own agent already has.

### Templating

`{{input}}` is whatever was passed in when the graph started. `{{node_id}}` reads that node's own past output, and fails the run if it hasn't produced one yet - that's almost always a mistake worth catching rather than sending a half-empty prompt. `{{node_id?}}` reads it the same way but falls back to a placeholder instead of failing, which is what a loop-back node needs: the first time it runs, there's no critique yet. `{{node_id|default:"some text"}}` falls back to a literal of your own instead of the built-in placeholder.

## An example

A draft that a reviewer can genuinely reject, a human sign-off before it goes out, then a final format pass:

```json
{
  "name": "research-and-verify",
  "agent": "assistant",
  "entry": "draft",
  "nodes": [
    { "id": "draft", "type": "agent",
      "prompt": "Write about {{input}}. Earlier critique: {{verify?}}",
      "next": "verify" },
    { "id": "verify", "type": "verifier",
      "prompt": "Review for unsourced claims:\n\n{{draft}}",
      "verdicts": { "pass": "review_human", "fail": "draft" } },
    { "id": "review_human", "type": "human",
      "ask": "Approve publishing this?\n\n{{draft}}",
      "next": "publish" },
    { "id": "publish", "type": "agent",
      "prompt": "Format as final output:\n\n{{draft}}\n\nHuman decision: {{review_human}}" }
  ]
}
```

If `verify` says "fail," the flow goes back to `draft` - which now sees the critique through `{{verify?}}` - instead of just trying again blind. If it says "pass," a person signs off before `publish` ever runs.

## Defining, running, and inspecting

An agent defines and runs its own graphs conversationally (`manage_graph`, `run_graph`, `inspect_graph_run`), or you can do it directly:

```bash
pepe graph import research.json                      # the file names its own agent
pepe graph list --agent assistant                    # every graph for that agent
pepe graph run assistant research-and-verify --input "the Q3 numbers"
pepe graph runs --agent assistant                    # every run, including paused ones
pepe graph inspect grun_a1b2c3d4                      # full history of one run
```

Importing checks the whole structure at once - unknown targets, a node that isn't allowed to name a given agent, a tool a node reaches for that the agent doesn't actually have - and reports every problem it finds, not just the first.

A run that reaches a `human` node comes back `waiting_human`, with exactly what it asked. Resolve it whenever the answer is ready:

```bash
pepe graph resume grun_a1b2c3d4 "yes, ship it"
```

Nothing about the run is lost while it waits - it stays parked exactly where it stopped, for as long as it takes.

## Running on a schedule

```bash
pepe graph schedule assistant research-and-verify --schedule "0 8 * * 1" --deliver "telegram:123456789"
```

Same mechanism as a [scheduled](../scheduled/) prompt or flow, just a different kind of job underneath. A scheduled graph that pauses on a `human` node still waits for a person - a timer starting the run doesn't make anyone available to answer it sooner.

<div class="note"><strong>A verifier that never agrees can't loop forever.</strong> Every graph has a step budget - 25 by default, and you can raise it up to 100 - so a revise loop that never converges fails cleanly once it's spent, instead of running forever. And trust doesn't blur across a whole run: a node only starts untrusted if it actually reads something that came from outside content (a fetched page, an uploaded document), and only that call loses its pre-approved tools - a node reading nothing but clean state runs fully trusted even in a run where some other branch touched something external.</div>
