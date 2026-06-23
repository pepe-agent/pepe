---
title: Secrets
description: The three ways to give Pepe a credential, what each one really protects, and an honest account of what none of them do.
---

Pepe needs credentials: a model provider's API key, a bot token, a webhook signing secret. There are three ways to give it one, and they add up rather than replace each other.

## 1. An environment variable (the default, unchanged)

```jsonc
"api_key": "${OPENAI_API_KEY}"
```

The config file holds the *name*, never the value, so a leaked backup or a careless commit gives nothing away. This is how Pepe has always worked and nothing about it changes.

## 2. A vault

A config value may say **where the secret lives** instead of holding it. Pepe fetches it at the moment it is needed:

```jsonc
// 1Password
"api_key": "exec:op read op://Work/openai/key"

// HashiCorp Vault
"api_key": "exec:vault kv get -field=key secret/openai"

// AWS Secrets Manager
"api_key": "exec:aws secretsmanager get-secret-value --secret-id openai --query SecretString --output text"
```

Those are three examples, not three integrations. **The whole contract is: a command that prints the secret on stdout.** Pepe does not know what 1Password is, and there is no list of supported vaults to be added to. The macOS keychain (`security find-generic-password -w -s openai`), `gcloud secrets versions access`, `pass show`, a Bitwarden CLI, and a script you wrote this morning all work today, because they all print a secret when you run them.

A file works too, which is what a Docker or Kubernetes secret mount is:

```jsonc
"api_key": "file:/run/secrets/openai_key"
```

### What a vault buys you

You **revoke a key in the vault** and it stops working within a minute, with no ssh, no edit, no restart. The secret is **not in the environment**, so an agent tricked into running `env` finds nothing to find. And the vault knows who read what, which an environment variable never will.

### If your vault needs a credential of its own

Most do: a service-account token, an address, a profile. Name those, and only those:

```jsonc
"secrets": { "vault_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

Pepe has no idea what that variable means. It passes it to your resolver and nothing else from the environment goes with it, so a resolver fetching one secret cannot read the others on its way past.

### The honest costs

The resolved value is **cached in memory for 60 seconds**, because opening a vault takes a few hundred milliseconds and a busy Pepe would otherwise pay that on every model call. So a secret does live in the process for up to a minute. This narrows the window; it does not abolish it.

And a vault that is locked or unreachable reads as an **unset** secret, never a wrong one. Pepe would rather tell you it has no key than authenticate with half of one.

## 3. Neither: the agent never sees any of it

Whichever of the two you use, **the agent's shell does not inherit Pepe's secrets**.

This is worth spelling out, because the `${ENV_VAR}` scheme invites a comfortable half-truth. It keeps secrets out of the config *file*, which is real. It used to do nothing at all about the *agent*, because the secret still had to exist somewhere for Pepe to use it, and that somewhere was the process whose child the agent's shell is. `echo $OPENAI_API_KEY` returned the key. So did `env`, which is a single word for a prompt injection to reach.

Now a command the agent runs gets Pepe's environment minus its credentials: every `${VAR}` the config points at (reading it is what makes it a secret Pepe holds) and every variable whose name says it is one (`GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`). `PATH`, `HOME` and the rest of the ordinary environment stay, because an agent that cannot find `git` is a broken agent, and a broken agent gets its guard rails torn off by an irritated human.

<div class="note"><strong>This is not a sandbox and does not pretend to be.</strong> An agent that can run shell can read any file you can read. What it closes is the cheapest, most likely leak by a wide margin, and it stops "the config has no secrets in it" from being a sentence that means less than it sounds like.</div>

## When the task *is* the credential

Sometimes the job you give the agent is itself credentialed: *"find the Postgres login in 1Password and run the migration."* You want to ask for that in plain language and have the agent work it out, the way it works everything else out, with no per-secret wiring on your side.

That is the one case where the agent needs a secret in its own shell: the vault's CLI (`op`) and the token that unlocks it. So there is a deliberate opt-in. Name the vault token in `secrets.expose_env` and it survives the scrub for the agent's shell:

```jsonc
"secrets": { "expose_env": ["OP_SERVICE_ACCOUNT_TOKEN"] }
```

Now the agent can run `op` on its own: `op vault list`, `op item get "Prod DB"`, and use what it finds. The built-in **`vaults` skill** teaches it the whole flow, including the rule that matters: reach for **`op run`** and **`op inject`**, which hand the secret to a command or a template without the value ever being printed, rather than `op read`-ing it into the open. The agent installs `op` itself if it is missing. And if the token is present but still scrubbed from its shell, the agent can add the name to `expose_env` itself through the permission-gated `config_set` (a list of names, never a value), rather than waiting on you to open the gate.

<div class="note"><strong>This trades a boundary for fluency, on purpose.</strong> A 1Password service-account token only opens the vaults you scoped it to, so the blast radius is exactly that scope. Pepe also scrubs the exact value of every secret it holds out of tool output, and masks anything *shaped* like a credential it does not know (<code>PGPASSWORD=…</code>, <code>Bearer …</code>, a JWT), before it reaches the model or the trace. So a stray <code>env</code>, a verbose error, and even a value the agent reads with <code>op read</code> are caught. What is left is only a secret that neither Pepe knows nor looks like one; the skill steers toward <code>op run</code>, and the token's scope bounds the rest. Use a narrowly-scoped token, or don't turn this on.</div>

## If a token gets pasted into the chat

It is compromised. Not because of where it landed, but because of where it has already been: typed into a chat means sent to the model provider, written into the conversation, and written into the trace on disk.

Pepe **saves it and tells you** rather than refusing the write, because refusing does not un-leak anything, it only leaves you stuck. Revoke it, reissue it, and put the new one in an environment variable or a vault. `pepe doctor` keeps saying so until you do.
