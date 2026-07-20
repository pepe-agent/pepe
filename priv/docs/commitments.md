# Commitments - follow-ups noticed automatically

A **commitment** is not something you create with a tool call in the moment - it's
noticed automatically after a turn, from what was actually said. Two shapes:

- The user asks to be reminded of something ("me lembra de mandar o relatório
  sexta"). Prefer calling `watch` yourself when you catch this in the moment - it's
  the more precise, deliberate way to do the same thing. Commitments exist as the
  safety net for when you don't.
- You yourself promise a follow-up ("let me check the deploy and I'll tell you
  tomorrow"). There is no tool call for this - it's exactly the gap commitments
  exist to close. Don't try to call `watch` on your own behalf; just say what you're
  going to do, and let it be noticed.

This only runs on an agent with `commitments` turned on (a per-agent flag) **and** a
`utility_model` configured - without both, nothing is extracted, and saying you'll
follow up on something does not create a durable record of it on its own.

## What happens after you say it

A cheap model call reads the last exchange, and if it finds a genuine follow-up,
stores it with a confidence score and (when resolvable) a due time. Below a
threshold, or when the due time didn't resolve ("in a bit" isn't a date), it lands
**awaiting confirmation** - you'll be asked directly ("did you want me to remember
this?") rather than it silently tracking something nobody actually asked for.
Otherwise it's scheduled outright.

## What happens when it's due

This is the part worth understanding, because the two kinds of commitment are
delivered completely differently:

- **The user's own reminder** fires a plain message at the right time - a canned
  text, the same as a `watch` firing.
- **Your own promise** does **not** just send a reminder that you promised
  something. It re-runs your session with a fresh instruction: *actually do the
  thing, then reply with what you found*. The reply that goes out is your real
  answer, not a template saying you're "checking." Never treat "I said I'd follow
  up" as satisfied by a message that says so - only by one that actually followed
  up.

## Managing them (`commitment` tool)

- `list` - show what's currently tracked (awaiting confirmation or scheduled).
- `confirm id: <id>` - promote an awaiting one. If its due time never resolved, pass
  `due_when` too (e.g. `"tomorrow"`, `"Friday"`).
- `cancel id: <id>` - drop it.

Use `confirm`/`cancel` when the user answers your "did you want me to remember
this?" question - that's the one thing you're expected to act on for a commitment
in this state.
