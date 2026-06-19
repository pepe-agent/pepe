# Find and use a secret from a vault - 1Password, HashiCorp Vault, Bitwarden, Doppler, `pass`, the macOS keychain, AWS/GCP secret managers - when a task needs a real credential (a database login, an API key) without writing the secret to disk.

Use this when the user says something like "get the Postgres login from my vault and run the
migration" or "use the credentials in 1Password". You discover and use the secret yourself,
conversationally. There is no per-secret setup to do first.

The shape is the same whatever vault it is, so learn the shape, not one tool:

1. **The tool must be installed.** Check (`op --version`, `vault --version`, `bws --version`,
   `doppler --version`, `pass version`). Install if missing - look up the command for the
   OS rather than guessing.
2. **You must be authenticated.** The token that opens the vault reaches your shell only
   when the operator allowed it in `secrets.expose_env` (below). Verify before reading
   anything (`op whoami`, `vault token lookup`, ...). If it fails, stop and tell the operator
   exactly what is missing - do not keep retrying.
3. **Discover, then use.** List and read to find the item and its field names, then use it.

## Getting the vault open (the opt-in)

By default Pepe strips vault-opening tokens from your shell, so a task cannot quietly reach
them. To use one, its name must be listed in `secrets.expose_env` - then it survives the scrub:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }   // or VAULT_TOKEN, DOPPLER_TOKEN, BWS_ACCESS_TOKEN, ...
```

If `op whoami` (or any lookup) reports the token missing - "No accounts configured",
"authenticate using OP_SERVICE_ACCOUNT_TOKEN", or your own `echo ${#OP_SERVICE_ACCOUNT_TOKEN}`
prints 0 - that is the scrub: the token exists in Pepe's environment but has not been exposed
to your shell yet.

**Do not stop and hand this back to the user. Fix it yourself:** call `config_set` to add the
token's name to `secrets.expose_env` (the user approves it through the permission prompt, since
it hands a credential to your shell). It takes effect on your very **next** command - Pepe
re-reads the config each time, no restart needed - so run your `op` command again right after.
Only if the token is not in Pepe's environment at all (never provided to the container) does
the operator have to supply it; say so plainly then.

## The rule that matters: inject, do not print

Whenever you can, let the vault tool put the secret *into* the command instead of reading it
into a variable you pass around. The value then never appears in your output, the transcript,
or the trace on disk. Every good vault CLI has a "run" or "inject" mode for exactly this:

```bash
op run -- psql -h db -U app -d prod -c '...'          # 1Password
doppler run -- psql -h db -U app -d prod -c '...'     # Doppler
vault ... ; export ... ; # HashiCorp: read into env for one command, then use it
```

Only fall back to reading a raw value (`op read`, `vault kv get -field=...`) when a command
truly cannot take an injected one - and then use it in the same command, never echo it, log
it, or write it to a file.

## Per-vault quick reference

- **1Password (`op`)** - service-account auth via `OP_SERVICE_ACCOUNT_TOKEN`.
  `op vault list` · `op item list --vault Infra` (discover items in a vault) ·
  `op item get "Prod DB" --vault Infra` · `op read op://Infra/Prod DB/password` · inject:
  `op run -- <cmd>`, a whole `.env` of `op://` refs with `op run --env-file=.env -- <cmd>`,
  or a template with `op inject -i tpl`. (`op environment` needs the beta CLI - use a vault.)
- **HashiCorp Vault (`vault`)** - `VAULT_ADDR` + `VAULT_TOKEN`.
  `vault kv list secret/` · `vault kv get secret/prod/db` · one field:
  `vault kv get -field=password secret/prod/db`.
- **Bitwarden Secrets Manager (`bws`)** - `BWS_ACCESS_TOKEN`. `bws secret list` ·
  `bws secret get <id>`. (Personal Bitwarden is `bw`: `bw get password <name>` after
  `bw unlock`.)
- **Doppler (`doppler`)** - `DOPPLER_TOKEN`. `doppler secrets` · inject everything at once:
  `doppler run -- <cmd>` (its whole point - prefer this).
- **`pass`** - `pass ls` · `pass show path/to/secret`. GPG-backed, local.
- **macOS keychain (`security`)** - `security find-generic-password -w -s <name>`.
- **AWS / GCP** - `aws secretsmanager get-secret-value --secret-id X --query SecretString --output text`
  · `gcloud secrets versions access latest --secret=X`.

## Guardrails

- Never print a secret to the chat, a log, or a file. Prefer run/inject over read.
- The token is scoped: you can only reach what it was granted. Need something outside that?
  Ask the operator - do not try to widen it.
- A secret you fetched is not yours to keep: use it in the command that needs it and let it go.
