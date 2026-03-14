# MCP servers (external tools)

Connect **MCP (Model Context Protocol)** servers - Sentry, GitHub, ... - and their
tools become callable by agents as if built in. Servers launch over stdio on demand
(via `npx`, so **nothing to install manually**); tokens go in as `${ENV_VAR}` refs.

```bash
mix pepe mcp add sentry --command npx \
  --args "-y @sentry/mcp-server@latest --access-token ${SENTRY_AUTH_TOKEN}"
mix pepe mcp tools sentry     # launch it and list its tools (validate the connection)
mix pepe mcp list
```

Each MCP tool is exposed as `mcp__<server>__<tool>`. **Scoping is just the tool
allowlist** - to make an agent *read-only* against a server, give it only the read
tools and leave the mutating ones out:

```bash
mix pepe agent add backoffice --tools read_file,mcp__sentry__find_organizations,mcp__sentry__get_issue
# (no mcp__sentry__update_issue -> the agent can look, not change)
```

`mcp__sentry__*` grants all of a server's tools. MCP tools are risky, so each call
still goes through the permission gate. An agent with the `manage_mcp` tool can add
and validate servers itself from chat (secrets stay as `${ENV}` refs). Definitions
live in `~/.pepe/config.json` under `"mcp"`.

---

[Back to the docs index](../README.md#documentation)
