# Permissions

The **primary agent** - the one created on first `mix pepe setup` (the owner's own
agent) - is born **omnipotent**: every tool, super-admin over all agents
(`can_manage: ["*"]`), and a `"*"` auto-approve grant so it runs any tool without a
prompt. It can do everything via chat from the start. Agents you add later are
scoped normally.

Before a **risky** tool runs - running code (`bash`, `run_script`), writing/moving
files, changing config, or any plugin tool - Pepe asks you to authorize it
(unless the agent has approved it - `"*"` approves everything).
Read-only tools (`read_file`, `list_dir`, `fetch_url`, `web_search`, ...) run freely.

Each surface renders the prompt natively - **Telegram** shows inline buttons, the
**console** an arrow-key menu - but the four choices are the same everywhere:

| Choice | Effect |
|---|---|
| **Allow once** | just this call; ask again next time |
| **Allow for this session** | the rest of this session (forgotten on `/new` and on restart) |
| **Always allow** | from now on - persisted on the agent (`auto_approve` in `config.json`) |
| **Don't allow** | refuse; never remembered, so it's asked again |

Manage the persistent grants from chat with `/approve` (list), `/approve clear`, or
`/approve clear <tool>`. Surfaces with no human to ask (the HTTP API) run tools
without prompting.

---

[Back to the docs index](../README.md#documentation)
