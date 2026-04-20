# Watches - "notify me when X" (one-shot)

A **watch** is a durable, one-shot commitment: the user asks you to *check something
and tell them when it happens*, you set it up, it re-checks a condition on a timer in
the background, messages the user **once** when it's met, and then stops. Unlike a
scheduled task (a recurring cron job) or a heartbeat (a periodic pulse), a watch fires
exactly once and cleans itself up. Manage watches with the `watch` tool.

A watch is durable - it survives a restart and this session closing - and it delivers
back on the **channel it was created from** (Telegram push, a WebSocket `"watch"`
event, or the console). Creating one is gated: it goes through the human permission
prompt unless pre-approved, so confirm the condition and where to notify first.

## Two trigger tiers - keep checking cheap

- **`probe`** - a shell command polled every interval, **no LLM per check** (so it
  costs no tokens). Success = exit 0, or set `probe_contains` to a string that must
  appear in the output. Prefer this whenever the condition is scriptable ("site is
  back", "log contains `Deploy complete`"). Minimum interval 30s.
- **`agent`** - re-ask the model each check, for conditions that need judgement. Costs
  one model call per check, so the minimum interval is higher: 300s.

The notification (`notify`) is either a fixed **`template`** (`message`, no LLM,
default) or an **`agent`**-composed message (`compose_prompt`, one LLM call, only when
it fires). The powerful combo is a free probe gating an agent message: poll cheaply,
and only let the model write the summary the moment it passes.

## Create a probe watch (`watch`)

```
watch create
  description: "site x back up"
  trigger: "probe"
  probe_command: "curl -sf https://x.example.com"   (success = exit 0)
  probe_contains: "OK"          (optional - success only if this appears in output)
  notify: "template"
  message: "✅ site x is back"
  interval_s: 60                (optional; min 30 for probe)
```

## Create an agent-judged watch

```
watch create
  description: "PR #4213 approved and CI green"
  trigger: "agent"
  check_prompt: "Is PR #4213 both approved and passing CI? Answer yes or no."
  notify: "agent"
  compose_prompt: "Tell me it's ready to merge, with the approver's name."
  interval_s: 600               (optional; min 300 for agent)
```

## Other actions

- `list` - show active watches (their trigger, interval, and check count).
- `pause id: <id>` / `resume id: <id>` - stop and restart checking.
- `cancel id: <id>` - remove it.

## Notes

- Watches only tick while a long-lived surface is up (`serve`, `gateway`, or an
  interactive `tui`/`chat`). Run **one at a time** against the same config - two would
  both tick and double-fire.
- An identical live watch (same trigger) is refused, so you can't stack duplicates.
  There's a cap of 50 active watches.
- State is persisted **before** delivery, so a crash can't double-fire.
