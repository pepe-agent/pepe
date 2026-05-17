---
title: Backup & extract
description: Archive the whole install, or lift one company out to run on its own server, and restore either with a single command.
---

Everything Pepe knows lives as files under `~/.pepe/` (or `PEPE_HOME`), so moving it is moving a directory. Two commands make an archive of it, and one restores either.

## Backup: the whole install

```bash
pepe backup                       # writes pepe-backup-YYYY-MM-DD.tgz
pepe backup --output /path/x.tgz
```

This is the "don't lose this machine" archive. It packs every company, every agent workspace, the shared space, sessions and the usage ledgers, and skips `data/mnesia/` (a disposable cache that rebuilds itself). Restored onto an empty box, it is the same machine again.

## Extract: one company, on its own

```bash
pepe extract acme                 # writes acme-extract-YYYY-MM-DD.tgz
pepe extract acme --output /path/acme.tgz
```

A company that grew up inside a shared install can leave to run on its own server. You cannot get there by copying a folder, because that company's rows are threaded through the shared `config.json` as `acme/agent` handles. Extract rewrites those handles to bare root names, so the archive is a **fresh single-tenant install that happens to be that company** — drop it on a new server and run.

Only that company travels: its agents, models, crons, watches, bots, tokens, workspaces and usage history. Nothing of the other tenants goes with it. If one of its agents depends on a **shared model** (one that lives at the root, not inside the company), that model is pulled into the archive too, so the bundle works on an empty box; the command tells you which ones.

## Restore: either archive

```bash
pepe restore acme-extract-2026-07-14.tgz
pepe restore pepe-backup-2026-07-14.tgz --force
```

A backup and an extract are the same shape — a `~/.pepe` inside a tarball — so one command restores both. It unpacks into `~/.pepe` (or `PEPE_HOME`). Because a restore **replaces** what is there, it refuses to write over a non-empty home unless you pass `--force`.

## Secrets are never in the archive

Secrets are `${ENV_VAR}` references, resolved at read time, so they live in your environment and never in the files (see [Secrets](/en/docs/secrets/)). That means they are **not** in a backup or an extract, by design. Every one of these commands prints the variables the archive references and whether each is currently set, so you can provision them on the destination. Re-export them there and the config resolves; forget one and whatever it unlocked is simply absent.
