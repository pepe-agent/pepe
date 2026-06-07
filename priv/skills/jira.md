# Work with Jira - find, create, update, and move issues through a workflow, and read a board or sprint - so a request in chat turns into the right ticket.

Use this when a task is about tracked work: "abre um card pra esse bug", "o que está no
sprint atual", "move a SUP-42 para em revisão", "quem está com essa tarefa". The goal is
that the user talks to you and the ticket happens, without them opening Jira.

## Prefer the connected tool

If the operator has wired an Atlassian/Jira MCP server, use those tools first - they handle
auth and speak Jira's data model directly, so there is no token to guard and no URL to
build. Check what you have before reaching for the shell. This skill's shell path is the
fallback for when no such tool is configured.

## The shell fallback: the REST API

Jira Cloud is a REST API. You need three things: the site (`https://YOURORG.atlassian.net`),
an account email, and an API token. Take the token from wherever the operator put it - a plain
environment variable (allowed through `secrets.expose_env`) works, and a vault injected with
`op run` is the tidier habit (see the `vaults` skill). Either way, reference it from the
environment (`$JIRA_TOKEN`); do not paste the literal value into the command, where it lands
in the trace.

```bash
# JIRA_TOKEN from the environment (a vault via op, or a plain exposed env var)
op run -- curl -s -u "you@org.com:$JIRA_TOKEN" \
  -H "Accept: application/json" \
  "https://YOURORG.atlassian.net/rest/api/3/search?jql=project=SUP+AND+statusCategory!=Done"
```

Common moves:

- **Find** - `POST /rest/api/3/search` with a JQL query. JQL is the whole skill: `project =
  SUP AND assignee = currentUser() AND status != Done ORDER BY updated DESC`.
- **Read one** - `GET /rest/api/3/issue/SUP-42`.
- **Create** - `POST /rest/api/3/issue` with `{fields: {project, summary, description,
  issuetype}}`. The description is Atlassian Document Format (a JSON doc), not Markdown.
- **Comment** - `POST /rest/api/3/issue/SUP-42/comment`.
- **Move** - transitions are their own endpoint: `GET .../transitions` to see the allowed
  next states and their ids, then `POST .../transitions` with the id. You cannot just set
  `status`; you transition through the workflow.

## Manners

- Search before you create - a duplicate ticket is noise. `jql` on the summary first.
- Creating, commenting, transitioning, and assigning change shared state, so the permission
  gate asks first; for anything that others will see (a public comment, closing someone
  else's ticket), confirm with the user.
- Put enough in a new ticket that the next person can act on it: what happened, where, how
  to reproduce. A one-line ticket is a second conversation waiting to happen.
