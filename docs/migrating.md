# Migrating from another runtime

Already running another agent runtime? Import its setup so you can try Pepe against your
existing models and agents without redoing everything by hand.

```bash
mix pepe migrate openclaw --dry-run     # see the plan, write nothing
mix pepe migrate openclaw               # apply it
mix pepe migrate hermes --from /path/to/home
```

`--from` points at the source's home directory (otherwise the source's default is used:
`~/.openclaw` or `~/.hermes`). `--dry-run` prints exactly what would be imported and
skipped, without touching your config.

## What comes over

- **Model connections** become Pepe models (base URL, upstream model id, and the API key,
  kept as a `${ENV_VAR}` reference when the source used one; a raw key is imported and
  flagged so you can move it to an env var).
- **Agents** become Pepe agents: the persona (the source's `AGENTS.md` / `SOUL.md`, a
  named personality, or a whole profile) becomes the agent's system prompt, `MEMORY.md` /
  `USER.md` are copied into the agent's workspace, and the model and temperature come too.
- **Tools** are mapped best-effort: source tool ids that match a real Pepe tool are kept;
  the rest are dropped and the agent falls back to a sensible default set. Review each
  agent's tools after importing.
- **Skills** (each source's `SKILL.md` folders) are copied into Pepe's skills.
- **Channels**: a **Telegram** bot token (and allowed chats) is set as the default bot;
  **WhatsApp**, **Slack** and **Microsoft Teams** connections are created from the source's
  credentials as webhook connections (finish any missing field on the Integrations page).

## What is reported, not mapped

- **Discord** and **Google Chat** in the sources use a gateway/service-account model whose
  credentials do not fit Pepe's webhook setup, so they are listed for a fresh setup rather
  than half-migrated. Other channels (Signal, ...) are listed too.
- Anything the source stored in a shape with no Pepe equivalent is noted in the report,
  never silently dropped.

## After importing

1. Check the secrets: any model whose key came in as a `${ENV_VAR}` needs that variable
   exported; a raw key should be moved to one.
2. Review each agent's tools.
3. `mix pepe run <agent> "hello"` to confirm it talks, then wire up channels.

The import is additive and safe to dry-run first. It never overwrites a workspace file
that already has content.

---

[Back to the docs index](../README.md#documentation)
