# Choose how to get a coding job done - by hand, a saved script, a batched tool script, or a dedicated coding agent - and hand off well when you do.

"Write some code" is not one task. A one-line fix, a self-contained script, several of
your own tool calls chained together, and a real multi-file feature are different shapes
of work, and each has a different right tool. Picking the wrong one wastes turns (doing a
five-file refactor by hand, one `edit_file` at a time) or wastes capability (reaching for
an external coding agent to run one script). This skill is the decision guide; the actual
mechanics of each option live in their own skill or tool description, referenced below
rather than repeated here.

## Pick by shape, not by habit

- **A small, local edit** (a few lines, one or two files, you already know exactly what
  to change) - just do it: `read_file`/`edit_file`/`write_file` directly, no delegation of
  any kind. Delegating this wastes a round-trip on something faster to do yourself.
- **A self-contained program** (parse this file, transform this data, call this API, do
  this one computation) - write it and run it with `run_script`. See the **`write-a-script`**
  skill for the full how-to; this skill only covers when to reach for it.
- **Several of your OWN tool calls, chained, in one turn** (read five files and combine
  them, loop over a list calling a tool per item, branch on one tool's result) - `run_code`.
  Not the same thing as `run_script` - see below, they are easy to confuse from their names.
- **Groundwork before you write anything** (survey how three modules already do something
  similar, read several docs at once, compare a few files) - `delegate`, to parallelize the
  *reading*. It cannot write the code for you - see below.
- **A real, multi-file coding job** (add a feature across a few files, port a module, write
  a test suite and make it pass - work that would swamp the conversation if done turn by
  turn) - a dedicated external coding agent (`claude`, `codex`), run non-interactively
  inside `tmux`. See the dedicated section below.

If you're unsure which bucket a task falls into, undersize rather than oversize the choice:
a script that turns out too small for `run_script` cost you nothing extra; an external
coding agent invoked for a two-line fix costs a slow round-trip and an unnecessary process
for something `edit_file` would have finished already.

## `run_code`: batch your own tool calls, not a general programming environment

`run_code` runs a short **Lua 5.3** script, sandboxed, that calls your other tools via
`pepe_call(name, args_table)` - many tool steps in one model round-trip instead of one
round-trip per call. It is not a place to write application logic in Python/JS/whatever;
it exists purely to orchestrate calls to tools you already have, and only tools that would
already run without asking anyone (the permission gate runs for real, on every call,
exactly as it would outside the script - if a call would need a human's yes, it's refused
inside the sandbox instead, never escalated).

Reach for it when a task needs several tool calls whose intermediate results you don't
need to see in the conversation - read several files and combine them, loop over a list
doing something per item, branch on one tool's result to pick the next step - not for
writing and running an actual program (that's `run_script`).

```lua
local out, err = pepe_call("read_file", {path = "reports/q1.csv"})
if err then return "failed: " .. err end
local lines = split(out, "\n")
local total = 0
for i = 2, #lines do              -- row 1 is the header
  local cols = split(lines[i], ",")
  total = total + tonumber(cols[3])
end
print("total: " .. total)
```

Helpers bound in the sandbox beyond stock Lua: `split(text, sep)` (literal-separator
split, 1-indexed table - prefer this over Lua's `string.gmatch` patterns for CSV/line
splitting), `json_decode(text)`, `json_encode(value)`, `trim(text)`, `contains(text, sub)`.
Every helper and `pepe_call` itself returns `(nil, error)` on bad input rather than
raising - always check `err`. The whole script shares one wall-clock budget (30s default,
120s max, set via `timeout_ms`) and a fixed memory budget; for a large data set, page
through it or filter inside the loop instead of loading everything into one table. `run_code`
cannot call itself from inside a script.

## `delegate`: parallel reading, never parallel writing

`delegate` spins up several fresh sub-agents at once, each answering one self-contained
instruction, and hands back only their answers. It is the right tool for *research done in
parallel* before or alongside a coding job - "read how billing and invoicing each handle
retries, summarize the pattern each uses" while you get on with something else, or as
groundwork before you write the change yourself.

It is never a way to get the coding itself done. A `delegate` worker inherits **only**
tools that need no permission - reading files, listing a directory, fetching a URL,
searching the web. Anything that writes, executes, installs, or deletes is stripped
before the worker starts, on purpose: three workers running at once would be three workers
each wanting to ask a human "may I run this?" at the same time, which isn't a question
that has a sane answer asked in triplicate. So `delegate` can survey code, but it cannot
edit a file, run a script, or produce "a finished change" - if you want that, write the
change yourself once the research comes back, hand it to `run_script`/`run_code`, or hand
it to an external coding agent.

A normal `delegate` call blocks until every worker answers (or times out) - fine for a
handful of quick reads. If a worker has real thinking to do and might run long, set
`"background": true` so it doesn't leave the conversation silent for minutes; you get a
result later instead.

## A real coding job: an external coding agent in `tmux`

For work big enough to swamp the conversation if done inline - a feature across several
files, a port, a test suite written and made to pass - shell out to a dedicated coding CLI
(`claude`, `codex`, and similar all support running non-interactively). These take a
prompt, work in the checkout directly, and can run for minutes. Install one on demand if
it's missing (see the **`install-tool`** skill) rather than assuming it's there.

Because a real run takes minutes and may stream output, never block one `bash` call on it -
run it inside a **tmux** session (see that skill for the send-keys/capture-pane mechanics)
so you can poll it instead of hanging the turn:

```bash
tmux new-session -d -s coding-job
tmux send-keys -t coding-job -l -- \
  'claude -p "Add pagination to the leads endpoint and cover it with tests. Run the tests."'
tmux send-keys -t coding-job Enter
# ...give it time, this is real work...
tmux capture-pane -t coding-job -p -S - | tail -40

# or, with codex, same pattern:
tmux send-keys -t coding-job -l -- 'codex exec "Port the CSV parser to the new module layout."'
tmux send-keys -t coding-job Enter
```

Poll `capture-pane` every so often rather than in a tight loop, and kill the session
(`tmux kill-session -t coding-job`) once you've read the result and don't need the pane
anymore. If the job needs a real credential (an API key, a database login) to do its work,
get it from the `vaults` skill and pass it the way the CLI expects (an env var, a flag) -
never paste a raw secret into the prompt text itself, and never let the agent hardcode one
into the code it writes.

### Framing the job (this is where it succeeds or fails)

- **State the goal and the done-condition.** "Make `mix test` pass with a test for the
  empty cart case", not "fix the cart". A coding agent is only as good as the target you
  give it.
- **Point at the ground truth.** Name the files, the command that proves success (the
  test, the build), and any constraint (do not touch the public API, keep it in this
  module).
- **Scope it to one outcome.** Hand off a coherent piece, not "refactor everything".
  Several clear handoffs beat one vague one - if the job naturally splits into independent
  pieces, consider `delegate`-style parallel *research* first to understand the pieces,
  then hand off each piece as its own focused run.

### Checking what comes back

Delegation does not transfer responsibility, from an external coding agent any more than
from `run_script` or `run_code`. Read the diff, run the tests yourself, and skim for the
obvious failure modes (a secret hardcoded, a test that asserts nothing, a TODO left
behind) before you present it as done. If it went wrong, a sharper prompt usually fixes
more than a dozen follow-up nudges.
