# Agent-to-agent routing: hand off & delegate

You can pull another agent into a conversation with the `send_to_agent` tool: send it
a message, get its reply back as your tool result. Use it to delegate work to a
specialist or ask a peer, then fold their answer into your own reply to the user.

This is *not* the same as complexity-based model routing (that's in `agents.md`):
this is about agents talking to each other.

## Sending to another agent (`send_to_agent`)

- `to: "billing" message: "What's the refund window for order 8842?"`: message the
  `billing` agent and get its reply.

The callee answers in a **fresh one-shot run**: it sees your message labelled with
your name ("Message from agent X: ...") and replies; that reply is what comes back to
you. Answering isn't itself "messaging", so the callee needs no return route to reply.

**`send_to_agent` never changes who the *user* is talking to.** It's a one-off: you
stay the agent answering this conversation, `send_to_agent` just lets you consult
another agent along the way. If the user is asking to talk to a specific agent from
now on ("connect me with billing", "let me talk to support directly"), not just this
one question, that's `switch_agent`, below, not `send_to_agent`.

## Handing off the whole conversation (`switch_agent`)

- `target: "billing"`: this conversation continues as `billing` starting with the
  *next* message. Your own reply to this turn still goes out as you ("sure, connecting
  you now"); you can't switch out from under the reply you're still giving.

This is the same thing as the user typing `/agent billing` themselves, just reachable
from a plain request instead of the slash command. The new agent starts with a fresh
context, same as `/agent` already does; it doesn't inherit this conversation's
history. Only switch when the request is genuinely "talk to X from now on"; confirm
with the user first if it's at all ambiguous which agent they mean, since it changes
who answers every message after this one, not just this reply.

## Who you may message (`can_message`)

Routing is a **directed allowlist**: each agent's `can_message` lists exactly who *it*
may message, so allowing `A -> B` does **not** allow `B -> A`. The same allowlist gates
both `send_to_agent` and `switch_agent`: if you can message an agent, you can also
hand the whole conversation to it. A call to a target outside your `can_message` is
refused, and refused discreetly ("Agent X isn't available to you") so the permission
model never leaks. Routes never cross a project boundary, even if an allowlist somehow
names an agent in another project.

`send_to_agent`'s allowlist check *is* its authorization, so it doesn't go through the
human permission prompt (the callee's own risky tools still do). `switch_agent` is a
bigger, harder-to-miss action for the human: it changes who answers every message
after this one, so it stays behind the normal permission gate unless pre-approved.

## Loop & hop guard

A run carries the chain of agents so far (`agent_chain`). Before a hand-off goes
through, `send_to_agent` refuses the call if:

- the target is **already in the chain** (that would loop, e.g. `A -> B -> A`), or
- the chain is **too deep** (a hard cap of 5 hops).

So a mis-configured web of routes can't spin agents forever: a chain always
terminates.

## Setting routes from chat (`set_route`)

Give an agent the `set_route` tool and it can add or remove routes itself, subject to
the permission prompt (it edits config):

- `to: "billing" action: "allow"`: add a route from you to `billing` (`from` defaults
  to the calling agent).
- `from: "sales" to: "billing" action: "deny"`: remove the `sales -> billing` route.

`action` defaults to `"allow"`. Routing stays directed: allowing `A -> B` never adds
`B -> A`. The owner can also wire routes from the CLI:

```bash
mix pepe agent route sales billing            # let sales message billing
mix pepe agent route sales billing --remove   # revoke it
```
