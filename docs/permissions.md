# Permissions

The **primary agent** (the one created on first `mix pepe setup`, the owner's own
agent) is born **omnipotent**: every tool, super-admin over all agents
(`can_manage: ["*"]`), and a `"*"` auto-approve grant so it runs any tool without a
prompt. It can do everything via chat from the start. Agents you add later are
scoped normally.

Before a **risky** tool runs (running code via `bash` or `run_script`, writing or
moving files, changing config, or any plugin tool), Pepe asks you to authorize it,
unless the agent has already approved it (`"*"` approves everything).
Read-only tools (`read_file`, `list_dir`, `fetch_url`, `web_search`, ...) run freely.

Each surface renders the prompt natively (**Telegram** shows inline buttons, the
**console** an arrow-key menu), but the four choices are the same everywhere:

| Choice | Effect |
|---|---|
| **Allow once** | just this call; ask again next time |
| **Allow for this session** | the rest of this session (forgotten on `/new` and on restart) |
| **Always allow** | from now on, persisted on the agent (`auto_approve` in `config.json`) |
| **Don't allow** | refuse; never remembered, so it's asked again |

Manage the persistent grants from chat with `/approve` (list), `/approve clear`, or
`/approve clear <tool>`. Surfaces with no human to ask (the HTTP API) run tools
without prompting.

## A grant remembers what it was given for

"Always allow bash" used to be a blank cheque. You would see the agent about to run
`ls build/`, wave it through, and that same permission then covered `rm -rf`, `sudo`,
and `curl | sh` forever. The person who signed it had been looking at a directory
listing.

Every call is classified first (deletes files, reaches the network, runs with elevated
privileges, runs embedded code, ...) and **the grant records the risks you were actually
looking at**. So:

```jsonc
"auto_approve": [
  "bash:none",                  // approved for bash calls that flag no risk
  "write_file:writes_file",     // ...and for writing files
  "bash:deletes+network"        // widened later, when you said yes to an rm and a curl
]
```

A call is allowed when every risk it carries was already approved. Approving `ls` lets
`cat` and `grep` through without asking again, which is the point: a gate that nags is a
gate people switch off. But the first `rm` flags `deletes`, is not covered, and stops to
ask, and the question names the thing you never said yes to. Say yes and the grant widens
in place; the list stays short enough to audit.

The old forms still work, unchanged:

| Grant | Means |
|---|---|
| `"*"` | every tool, every risk (the owner's own agent) |
| `"bash"` | a blank cheque on bash, as written by a Pepe from before this existed |
| `"bash:any"` | the same blank cheque, written knowingly |

**This is not a sandbox, and must not be read as one.** The classification reads the
command as text, and text lies: a command can be assembled at runtime, base64-decoded, or
hidden inside a script the agent wrote a moment earlier. What this closes is the gap
between *what a human looked at* and *what they actually signed*. It fails closed, in that
an unrecognised risk is never covered by a narrower grant. It does not make a container
that runs LLM-chosen shell into a safe place; that container still needs to be one you
would be willing to lose.

---

[Back to the docs index](../README.md#documentation)
