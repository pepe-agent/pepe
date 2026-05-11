# MCP servers - external tools

Connect **MCP (Model Context Protocol)** servers (Sentry, GitHub, ...) so their tools
become callable by agents. Servers launch over stdio on demand (via `npx`), so
nothing has to be installed manually.

## Add and validate a server (the `manage_mcp` tool)

1. **add** - register the server. Put the token as a `${ENV_VAR}` reference, never
   raw:

   ```
   manage_mcp add
     name: "sentry"
     command: "npx"
     args: ["-y", "@sentry/mcp-server@latest", "--access-token", "${SENTRY_AUTH_TOKEN}"]
   ```

   Ask the user to export `SENTRY_AUTH_TOKEN`. Do not ask them to paste the token to
   you, and do not offer to "just put it in for now".

   **If they paste it anyway, save the server.** Refusing does not help: by the time you
   see the token it has already been sent to the model provider and is in this
   conversation and in the trace on disk. It is compromised whatever you do next. The
   tool will save it and hand you a warning to pass on. Pass it on, plainly, once:
   the token must be **revoked and reissued**, the new one goes in an environment
   variable, and the config should then refer to it as `${...}`. Then carry on with what
   they asked for.

2. **tools** - launch it and list its tools live, to validate the connection and see
   what's available: `manage_mcp tools name: "sentry"`. Each tool is named
   `mcp__sentry__<tool>`.

3. **list** / **remove** - manage configured servers.

## Give an agent access - scope it read-only

An MCP tool's agent-facing name is `mcp__<server>__<tool>`. Because that goes into an
agent's ordinary tool allowlist, **scoping is just the allowlist**: add only the read
tools, leave the mutating ones out. Use `manage_agent`:

```
manage_agent add_tool  target: "backoffice"  value: "mcp__sentry__find_organizations"
manage_agent add_tool  target: "backoffice"  value: "mcp__sentry__get_issue"
# do NOT add mcp__sentry__update_issue -> the agent can look, not change.
```

`mcp__sentry__*` grants every tool of the server (use only for trusted, full-access
agents). MCP tools are risky, so each call still goes through the permission gate.

## Verify

After adding, run `manage_mcp tools <name>` - if it lists tools, the connection and
token work. If it errors, the token env var is probably unset or the package name is
wrong.
