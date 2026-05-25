---
title: Agent-to-agent routing
description: Let one agent hand work to another with the send_to_agent tool, governed by a directed allowlist that says exactly who may call whom.
---

Agents can message each other through the `send_to_agent` tool. Who may call whom is
governed by a **directed allowlist**: each agent's `can_message` lists the agents that
*it* is allowed to message. A route from `triage` to `billing` does not imply a route
from `billing` back to `triage`.

When an agent routes a message, the called agent answers in a fresh run, and its reply
comes back to the caller as the tool result. A hop limit and a cycle check stop chains
of routed calls from looping forever.

## Adding a route

```bash
# triage hands work to billing; billing can escalate to refunds
pepe agent route triage billing
pepe agent route triage refunds
pepe agent route billing refunds

# revoke a route
pepe agent route triage billing --remove

# or set it when creating the agent
pepe agent add triage --model mock --can-message billing,refunds
```

Routes are stored in `~/.pepe/config.json` as each agent's `can_message` list:

```jsonc
"agents": {
  "triage":  { "can_message": ["billing", "refunds"] },
  "billing": { "can_message": ["refunds"] },
  "refunds": { "can_message": [] }
}
```

`refunds` has an empty `can_message`, so it answers when it is called but it cannot
call anyone back. Because the allowlist is directed, granting the route from `billing`
to `refunds` grants nothing in the reverse direction.

An agent also needs `send_to_agent` in its `tools` list before it can route at all. The
allowlist decides who it may call, and the tool is what lets it place the call.

<div class="note"><strong>Project boundaries.</strong> Routes never cross a project
boundary. Bare peer names in <code>--can-message</code> resolve inside the agent's own
project, and the CLI refuses a route between two agents that live in different
projects.</div>

## Routing and the permission gate

The route allowlist *is* the authorization for the call. An operator already decided,
in configuration, that this agent may message that agent, so the `send_to_agent` call
itself is not put through the human permission gate. It simply runs.

That is exactly why the allowlist is directed and closed by default instead of
symmetric and open. The grant is narrow and explicit, one direction at a time, which is
what makes an ungated call safe to allow. A symmetric allowlist would silently hand the
callee a route back to its caller that nobody ever asked for.

The callee's own risky tools are a separate question, and they are still gated. When
`billing` runs `bash` or `write_file`, that call goes through the permission gate just
as it would if you had talked to `billing` yourself. Routing lets one agent reach
another, but it never launders that agent's permissions.

## Changing routes from chat

Give an agent the `set_route` tool and it can add or remove routes conversationally,
guided by the built-in `manage-routing` skill. The tool takes `{from, to, action}`,
where `from` defaults to the calling agent.

```text
Allow yourself to message the billing agent.
```

The agent calls `set_route` with `action: "allow"` and `to: "billing"`. Since this edits
configuration, `set_route` does pass through the permission prompt: you authorize the
new route before it is written to disk. Routing is still directed, so allowing this one
does not let `billing` message back.
