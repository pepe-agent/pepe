Use when the user asks to change which agents can talk to each other (routing).

Agent-to-agent messaging is a **directed allowlist**: each agent has a `can_message`
list of the agents *it* may send to. `A -> B` does NOT imply `B -> A` - they're set
independently.

To change a route, use `manage_agent`'s `allow_route`/`deny_route` actions:

- Allow a route: `{ "action": "allow_route", "target": "A", "value": "B" }`
  -> A may now message B.
- Remove a route: `{ "action": "deny_route", "target": "A", "value": "B" }`.
- `target` is the sender (the agent whose outbound routing changes); `value` is the
  recipient. To let *yourself* message B, target your own name.

This edits config, so the user is asked to authorize the change (it goes through the
permission prompt). Both agents must already exist, and you need `manage_agent`-level
authority (`can_manage`) over `target` - the same authority every other `manage_agent`
action needs over the agent it changes.

Tips:
- Routing is directional. To make two agents talk both ways, set both routes:
  `A -> B` and `B -> A`.
- Watch for loops: A->B->C->A is allowed to be configured, but a live message chain
  that would revisit an agent already in the chain is refused at send time.
- After changing routes, the agents that have the `send_to_agent` tool can use the
  new path immediately - no restart.
- To see current routes, read the config (the `config_get` tool) or list agents.
