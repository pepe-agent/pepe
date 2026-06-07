# Run and drive a long-lived or interactive process (a dev server, a REPL, an install that asks questions, a CLI that keeps a session) that has to stay alive ACROSS your tool calls.

Each `bash` call you make is its own short-lived shell: state does not carry from one to
the next, and a process you start in one call is gone by the next. When a task needs a
process that *stays up* between your turns, or a program that reads from a live terminal,
put it inside a **tmux** session and control that session from later `bash` calls.

Reach for this when: a server must keep running while you test against it; a command asks
an interactive question (a signin, a prompt, a `[y/N]`); or a session token has to survive
across several commands (see the `vaults` skill).

For a one-shot command, just use `bash`. For fire-and-forget background work whose output
you do not need to steer, a plain `&` or `nohup` is simpler than tmux.

## Setup

Check it is there with `tmux -V`. If missing, install it (macOS `brew install tmux`,
Debian/Ubuntu `apt-get install -y tmux`); if unsure of the OS, look it up rather than
guess. Keep one named session per job so you can find it again:

```bash
tmux new-session -d -s dev        # start a detached session named "dev"
tmux ls                           # list sessions
```

Target panes as `session:window.pane`, e.g. `dev:0.0`.

## Send input, read output

Sending keys and reading the screen are separate steps. Send, wait, then capture: a program
needs a moment to react, and capturing too soon shows you the prompt before the answer.

```bash
tmux send-keys -t dev:0.0 -l -- "mix phx.server"   # -l -- sends the text literally
tmux send-keys -t dev:0.0 Enter                     # Enter as its own key
# ...give it a second...
tmux capture-pane -t dev:0.0 -p | tail -30          # read the visible screen
tmux capture-pane -t dev:0.0 -p -S -                # -S - reads the whole scrollback
```

Control keys go by name: `C-c` (interrupt), `C-d` (EOF), `Escape`. Always split the text
and the `Enter` into two `send-keys` calls, so a stray newline in your text cannot fire a
command early.

## Watching an interactive prompt

When a command may stop and ask a human, poll the pane until you understand what it wants,
and only then answer. Never blind-fire a `y`.

```bash
tmux capture-pane -t dev:0.0 -p | tail -20          # what is it asking?
tmux send-keys -t dev:0.0 -l -- "y"; tmux send-keys -t dev:0.0 Enter
```

If the prompt needs something only the user has (a password, an MFA code, a choice you
cannot make), stop and ask them, and hand them the session name so they can attach in their
own terminal with `tmux attach -t dev`. Do not try to answer it yourself.

## Clean up

Kill the session when the job is done, so you do not leave servers running:

```bash
tmux kill-session -t dev
```
