# Permissions - how Pepe decides what a tool may do

Pepe asks the user before a **risky** tool runs, so an agent can be autonomous
without being dangerous.

## The layers

1. **Tool allowlist** - an agent can only call tools in its `tools` list. A capability
   is just having its tool. If a tool isn't listed, the model never sees it.
2. **Permission gate (per call)** - when a tool *is* called:
   - Read-only tools run freely: `read_file`, `list_dir`, `fetch_url`, `web_search`,
     `config_get`, `skill`, `docs`, `send_to_agent`.
   - Everything else (running code, writing/moving files, changing config, MCP tools,
     any plugin tool) needs **authorization** - the surface asks the user
     (Telegram buttons, console menu, dashboard prompt). Unknown tools default to
     risky (safe default).
   - Decisions: allow once / for this session / always (persisted on the agent's
     `auto_approve`) / deny.
   - A surface with no human to ask (the HTTP API) runs freely.
3. **In-tool guards** - some tools add their own scoping (e.g. `manage_channel` never
   touches the protected default bot; `manage_agent` only touches agents in
   `can_manage`; secrets must be `${ENV}` refs).

## The owner's primary agent

The first agent created at setup is born **omnipotent**: all tools, super-admin over
all agents (`can_manage: ["*"]`), and a `"*"` auto-approve grant so it never prompts.
Agents you add later are scoped normally - grant them only the tools and admin scope
they need.

## The rule of thumb

Give an agent the least it needs: the specific tools (including only the read MCP
tools for a query agent), and an admin scope of `[]` or a narrow list unless it's
genuinely an admin.
