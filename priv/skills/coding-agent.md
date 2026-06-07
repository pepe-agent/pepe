# Hand a large, self-contained coding job to a dedicated coding agent and collect the result, instead of writing every line yourself in the conversation.

Use this when the task is a real chunk of software work - "build this feature across a few
files", "port this module", "write a test suite and make it pass" - that would swamp the
chat if you did it inline, turn by turn. A focused coding agent works in the repository, runs
its own edit/build/test loop, and hands back a finished change. Your job becomes framing the
work well and checking what comes back, not typing each edit.

For a small edit, just do it yourself with `read_file`/`edit_file`/`write_file`. This is for
work big enough that delegating pays for the handoff.

## Two ways to delegate

**Inside Pepe** - the `delegate` tool spins up a sub-agent that shares your workspace and
returns a result. Use it for work that fits Pepe's own tools and does not need a full
repo-aware coding loop. It is the simplest option and needs nothing installed.

**An external coding CLI** - for heavy, repo-wide work, shell out to a dedicated coding
agent (`claude`, `codex`, and similar run non-interactively). These take a prompt and edit
the checkout directly. Install on demand, and because a real coding run takes minutes and may
stream, run it inside a **tmux** session (see that skill) rather than blocking on one `bash`
call:

```bash
# in a tmux pane, so it can run for minutes and you can watch it
claude -p "Add pagination to the leads endpoint and cover it with tests. Run the tests."
# or:  codex exec "..."
```

Poll the pane with `capture-pane` until it finishes.

## Framing the job (this is where it succeeds or fails)

- **State the goal and the done-condition.** "Make `mix test` pass with a test for the empty
  cart case", not "fix the cart". A coding agent is only as good as the target you give it.
- **Point at the ground truth.** Name the files, the command that proves success (the test,
  the build), and any constraint (do not touch the public API, keep it in this module).
- **Scope it to one outcome.** Hand off a coherent piece, not "refactor everything". Several
  clear handoffs beat one vague one.

## Checking what comes back

Delegation does not transfer responsibility. Read the diff, run the tests yourself, and skim
for the obvious failure modes (a secret hardcoded, a test that asserts nothing, a TODO left
behind) before you present it as done. If it went wrong, a sharper prompt usually fixes more
than a dozen follow-up nudges. And keep the credentials story intact: a sub-agent or CLI is
still an agent - do not hand it a raw secret, use the `vaults` skill.
