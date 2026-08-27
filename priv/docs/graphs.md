# Graphs - multi-step workflows with shared state and a real revise loop

A graph is a named workflow of nodes and edges: state that survives across SEPARATE
model calls, and a `verifier` node that can send the flow back to an earlier node
instead of just retrying blind. Reach for it when a job is genuinely multi-step with
real branching - draft, then a real review that can reject and send it back, then a
human sign-off, then publish - not for a single question (just answer it) or a fixed
sequence you've already proven works (that's a [flow](../flow.md), which replays exact
past tool calls with no model call at all).

Use `manage_graph` to define one, `run_graph` to execute it, `inspect_graph_run` to
check on a run later.

## Node types

No new template language beyond a single `{{key}}` substitution. Five node types:

- **agent**: calls a model with a rendered `prompt`; the reply becomes `{{id}}` for
  every later node. `next` is the following node id; omit it to end the graph here.
- **verifier**: same call as `agent`, but its reply must end on a line containing
  exactly one word from `verdicts`' keys (e.g. `{"pass": "publish", "fail": "draft"}`).
  That word picks the next node - and it can be an EARLIER one, which is the real
  revise loop: the earlier node sees the critique via `{{this_verifier_id}}`.
- **human**: no model call. The run pauses (`waiting_human`) and returns; a human's
  later answer (`mix pepe graph resume`, or someone tells you their answer and you
  relay it) becomes `{{id}}`.
- **parallel**: fans `tasks` out to read-only workers, exactly like `delegate` (same
  restrictions - workers may read, not act). The combined answer becomes `{{id}}`.
- **tool**: calls one existing tool directly, gated exactly like a normal tool call,
  restricted to tools already in your own `tools` list. Cannot name `run_code`,
  `delegate`, or `run_graph` - use the matching node type instead.

## Templating

`{{input}}` is the run's input string. `{{node_id}}` reads that node's past reply and
fails the run if it hasn't run yet - use this only for something guaranteed to have
already run. `{{node_id?}}` reads it or falls back to a placeholder - use this for a
loop-back target reading its own upstream on the first pass, before any critique
exists yet. `{{node_id|default:"..."}}` falls back to your own literal text instead of
the placeholder.

## Defining one

```text
manage_graph(action: "import", graph_name: "research-and-verify", entry: "draft", nodes: [
  {id: "draft", type: "agent", prompt: "Write about {{input}}. Critique: {{verify?}}", next: "verify"},
  {id: "verify", type: "verifier", prompt: "Review for unsourced claims:\n\n{{draft}}",
   verdicts: {pass: "review_human", fail: "draft"}},
  {id: "review_human", type: "human", ask: "Approve publishing this?\n\n{{draft}}", next: "publish"},
  {id: "publish", type: "agent", prompt: "Format as final output:\n\n{{draft}}\n\nHuman decision: {{review_human}}"}
])
```

Import always reports every problem it finds, not just the first - fix all of them and
retry, don't guess which one mattered. A node naming an agent other than yourself needs
that agent in your own `can_message`; naming yourself needs nothing extra.

## Running one

```text
run_graph(graph_name: "research-and-verify", input: "the Q3 numbers")
```

Returns a run id and status. `"done"` includes the terminal node's output right there.
`"waiting_human"` includes exactly what it's asking - relay that to the person, then
resolve it later (`mix pepe graph resume RUN_ID "their answer"`, or tell them that
command). The run stays parked until then; nothing is lost. `inspect_graph_run(run_id:
"...")` shows the full history any time, including after it's done.

A graph cannot call `run_graph` on itself, directly or through a chain of calls - same
"workers cannot delegate" rule `delegate` already enforces for its own kind of fan-out.

## Safety

Every step budget defaults to 25 (max 100) - a verifier that never converges fails
cleanly at the cap instead of looping forever. Taint is tracked per state key, not as
one flag for the whole run: a node only starts untrusted if it actually reads a key
that came from outside content (a fetched page, a document), and that withdraws its
own `auto_approve` for that call only - a node reading nothing but clean state runs
fully trusted even in a run where some other key is tainted.
