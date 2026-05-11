# Admin agents - manage other agents from chat

The `manage_agent` tool lets one agent **administer and train another** - a scoped
"admin agent". An owner talking to you in chat can have you shape another agent's
persona, model, tools, and memory, or spin up a whole new agent, without touching the
CLI. Persona and memory live in the target's workspace (`SOUL.md`, `MEMORY.md`);
model and tools live in its config.

It's a risky tool - it's gated by the tool allowlist and goes through the human
permission prompt. Confirm changes with the user before you make them.

## What you can do (`manage_agent`)

**set_flag** turns a target's switch on or off. The one worth knowing is
`trust_untrusted_content`: with it on, that agent may act on content a stranger sent it
(a document, a fetched page) instead of falling back to asking. It is off by default and
turning it on is a real trust decision, so you cannot flip it on from a conversation that
has itself taken in a document. Confirm with the operator before you set it.


Every call takes an `action`, and most take a `target` (the agent to act on) and a
`value` (the payload):

- `action: "list"` - show which agents you're allowed to manage. Needs nothing else.
- `action: "get" target: "sales"` - dump the target's definition (model, tools,
  can_message, a persona preview).
- `action: "create" target: "sales"` - create a new agent. Optional `value` seeds its
  starting persona; it's created with no tools, so grant them next.
- `action: "set_persona" target: "sales" value: "You are a friendly sales rep..."` -
  overwrite the target's persona (its `SOUL.md`).
- `action: "set_model" target: "sales" value: "gpt-4o"` - point it at a configured
  model connection. The model must already exist as a connection.
- `action: "add_tool" target: "sales" value: "web_search"` - grant one tool. The tool
  must be a real built-in / MCP / plugin tool name.
- `action: "remove_tool" target: "sales" value: "bash"` - revoke one tool.
- `action: "remember" target: "sales" value: "Our refund window is 30 days."` - append
  a durable fact to the target's `MEMORY.md`. This is how you *train* an agent by chat.

## Who you may administer (`can_manage`)

Authority is a **directed, per-agent allowlist** on the calling agent, and it defaults
to closed. What your `can_manage` holds decides every `manage_agent` call:

- **omitted / null** -> you may manage **only yourself**.
- **`[]`** -> you may manage **nobody, not even yourself** (a locked agent - e.g. a
  client-facing one that must not alter itself).
- **`["sales", "support"]`** -> **exactly those** agents. The list is exhaustive; add
  your own name to also manage yourself.
- **`["*"]`** -> **every** agent (an explicit super-admin).

A call against a target outside your `can_manage` is refused - and refused discreetly
("Agent X isn't available to you"), so the permission model never leaks to the end
user. The owner grants this scope deliberately from the CLI:

```bash
mix pepe agent manage owner sales      # let "owner" administer "sales"
mix pepe agent manage owner "*"        # make "owner" a super-admin over every agent
```

## A typical flow

Asked to "stand up a returns bot", you'd `create` it, `set_persona`, `set_model`,
`add_tool` for what it needs, then `remember` a key policy fact - confirming each
step with the user as you go:

```
manage_agent action: "create" target: "returns" value: "You handle product returns."
manage_agent action: "set_model" target: "returns" value: "gpt-4o-mini"
manage_agent action: "add_tool" target: "returns" value: "web_search"
manage_agent action: "remember" target: "returns" value: "Returns accepted within 30 days with a receipt."
```

To let the new agent hand conversations to a specialist, set up a route - see
`routing.md`.
