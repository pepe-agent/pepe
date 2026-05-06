# Agent-to-agent routing

Agents can message each other through the `send_to_agent` tool, governed by a
**directed allowlist**: each agent's `can_message` lists who *it* may message, so
`triage -> billing` does **not** imply `billing -> triage`. The called agent answers in
a fresh run and its reply comes back as the tool result; a hop limit and cycle check
stop chains from looping.

```bash
# triage hands work to billing; billing can escalate to refunds
mix pepe agent route triage billing
mix pepe agent route triage refunds
mix pepe agent route billing refunds
mix pepe agent route triage billing --remove   # revoke a route

# or set it when creating the agent
mix pepe agent add triage --model mock --can-message billing,refunds
```

```jsonc
"agents": {
  "triage":  { "can_message": ["billing", "refunds"] },
  "billing": { "can_message": ["refunds"] },
  "refunds": { "can_message": [] }
}
```

`refunds` has an empty `can_message`, so it answers when called but cannot call anyone
back. Because the allowlist is directed, `billing -> refunds` grants nothing in the
reverse direction.

Add `send_to_agent` to an agent's `tools` to let it route. The route allowlist is
the authorization, so the call itself isn't put through the human permission gate,
but the callee's own risky tools still are.

Routes can also be changed **from chat**: give an agent the `set_route` tool and it
can add or remove routes (`{from, to, action}`, where `from` defaults to itself),
guided by the `manage-routing` skill. Since it edits config, the change goes through
the permission prompt.

---

[Back to the docs index](../README.md#documentation)
