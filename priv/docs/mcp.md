# MCP servers - external tools

Connect **MCP (Model Context Protocol)** servers (Sentry, GitHub, ...) so their tools
become callable by agents.

A server is one of two kinds, and which one decides what you need from the user:

* **Remote** - a `url` reached over HTTP. Nothing is installed. You need the URL and a
  credential.
* **Local** - a `command` launched over stdio on demand (via `npx`), so nothing has to
  be installed manually either, but the machine running Pepe must have that command.

Prefer remote when the user gives you a URL. It has fewer ways to fail: no missing
`npx`, no package name to get wrong, no local process to spawn.

## Add and validate a server (the `manage_mcp` tool)

1. **add** - register the server. Put the token as a `${ENV_VAR}` reference, never
   raw.

   Remote:

   ```
   manage_mcp add
     name: "memclaw"
     url: "https://memclaw.net/mcp"
     headers: {"Authorization": "Bearer ${MEMCLAW_API_KEY}"}
   ```

   Local:

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

   For a remote server, `transport` is left unset: it negotiates by itself. Pin it to
   `"sse"` or `"streamable"` only after a connection fails in a way that says the
   negotiation guessed wrong.

3. **list** / **remove** - manage configured servers. For a remote server, `list` also
   says what credential it has, which is what tells a `401` apart from a bad URL.

4. **logout** - forget a remote server's stored OAuth grant. Only ever removes access.

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

## A remote server that wants OAuth

Some hosted servers take no API key and answer `401` until someone signs in. **You cannot
do that sign-in, and there is no action here for it.** It needs a browser and a human at
it. Do not try to work around that, and do not report it as a broken connection. Say what
it is and hand over the one command:

```
mix pepe mcp login <name>
```

(Or: the Sign in button on the dashboard's MCP page.) After they run it,
`manage_mcp tools <name>` works and everything else is the same.

**Never offer to walk someone through an authorization link yourself.** Producing a link
and asking a person to authorize it is the exact shape of a phishing message; that it is
you asking is not something they can verify, and it is not a habit worth teaching them.
Point at the command and let the tool they already trust produce the link.

## Verify

After adding, run `manage_mcp tools <name>` - if it lists tools, the connection and
credential work. If it errors:

* **A local server**: the token env var is probably unset, or the package name is wrong.
* **A remote server**: `401`/`unauthorized` means the credential, not the URL - either the
  `${ENV_VAR}` behind the header is unset, or the server wants the OAuth sign-in above.
