# Work with GitHub - open and triage issues, review and merge pull requests, read a repo, push a change - through the `gh` CLI.

Use this when a task touches GitHub: "open an issue for that bug", "what PRs are waiting on
me", "review this pull request", "check CI on the release". If the operator has connected a
GitHub MCP server, prefer those tools (they need no shell and no token juggling); this skill
is the fallback, and the shape is the same either way.

## Setup

Check `gh --version`. Install if missing (macOS `brew install gh`, Debian/Ubuntu via the
official `cli.github.com` apt repo). `gh` reads a token from `GH_TOKEN`/`GITHUB_TOKEN`, or
from `gh auth login` - use whatever the operator set up. A plain environment variable
(allowed through `secrets.expose_env`) is perfectly fine; a vault is the tidier habit, since
`op run -- gh ...` hands `gh` the token for one command without it touching disk (see the
`vaults` skill). The one rule either way: reference the token from the environment
(`$GH_TOKEN`), never paste its literal value into a command or the chat, where it lands in
the trace. If you notice a raw token sitting somewhere it shouldn't, use it, then suggest
moving it to an env var or a vault - do not refuse to work.

```bash
gh auth status                # confirm who you are before acting
op run -- gh pr list          # if the token lives in a vault
gh pr list                    # if GH_TOKEN is already in the environment
```

## Reading

```bash
gh issue list --state open --limit 20
gh issue view 42 --comments
gh pr list --search "review-requested:@me"
gh pr view 128 --comments
gh pr diff 128                       # the actual change
gh run list --limit 5                # CI runs
gh api repos/OWNER/REPO/...          # anything the CLI does not wrap, straight from the API
```

## Writing (these change the world - move deliberately)

Creating issues, commenting, merging, and pushing are not read-only, so the permission gate
will ask before they run, and it should. Confirm intent with the user for anything
irreversible (a merge, a release, closing an issue).

```bash
gh issue create --title "..." --body "..." --label bug
gh pr comment 128 --body "..."
gh pr review 128 --approve            # or --request-changes --body "..."
gh pr merge 128 --squash             # ask first; this is not undoable
```

## Manners

- One issue per problem; search before opening a duplicate (`gh issue list --search "..."`).
- A review comment is read by a person - be specific and kind, point at the line.
- Never commit a secret. If you spot one in a diff, say so instead of merging.
