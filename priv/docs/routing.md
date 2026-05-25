# Agent-to-agent routing - hand off & delegate

You can pull another agent into a conversation with the `send_to_agent` tool: send it
a message, get its reply back as your tool result. Use it to delegate work to a
specialist or ask a peer, then fold their answer into your own reply to the user.

This is *not* the same as complexity-based model routing (that's in `agents.md`) -
this is about agents talking to each other.

## Sending to another agent (`send_to_agent`)

- `to: "billing" message: "What's the refund window for order 8842?"` - message the
  `billing` agent and get its reply.

The callee answers in a **fresh one-shot run** - it sees your message labelled with
your name ("Message from agent X: ...") and replies; that reply is what comes back to
you. Answering isn't itself "messaging", so the callee needs no return route to reply.

## Who you may message (`can_message`)

Routing is a **directed allowlist**: each agent's `can_message` lists exactly who *it*
may message, so allowing `A -> B` does **not** allow `B -> A`. A message to an agent
outside your `can_message` is refused, and refused discreetly ("Agent X isn't available
to you") so the permission model never leaks. Routes never cross a project boundary,
even if an allowlist somehow names an agent in another project.

Because the allowlist *is* the authorization, a `send_to_agent` call doesn't go through
the human permission prompt - but the callee's own risky tools still do.

## Loop & hop guard

A run carries the chain of agents so far (`agent_chain`). Before a hand-off goes
through, `send_to_agent` refuses the call if:

- the target is **already in the chain** (that would loop - e.g. `A -> B -> A`), or
- the chain is **too deep** (a hard cap of 5 hops).

So a mis-configured web of routes can't spin agents forever - a chain always
terminates.

## Setting routes from chat (`set_route`)

Give an agent the `set_route` tool and it can add or remove routes itself, subject to
the permission prompt (it edits config):

- `to: "billing" action: "allow"` - add a route from you to `billing` (`from` defaults
  to the calling agent).
- `from: "sales" to: "billing" action: "deny"` - remove the `sales -> billing` route.

`action` defaults to `"allow"`. Routing stays directed: allowing `A -> B` never adds
`B -> A`. The owner can also wire routes from the CLI:

```bash
mix pepe agent route sales billing            # let sales message billing
mix pepe agent route sales billing --remove   # revoke it
```
