---
title: Install
description: Install Pepe and run the guided setup before creating agents.
---

Install the `pepe` binary, then run the guided setup. It creates the config file,
connects a model, and creates your first agent.

## 1. Install

One command installs the `pepe` binary.

```bash
curl -fsSL https://pepe-agent.com/install.sh | sh
```

Check it landed:

```bash
pepe help
```

Pepe stores its setup in `~/.pepe/config.json`. There is no database to run.

## 2. Guided setup (the fast path)

`pepe setup` walks you through provider auth, model choice, the first agent, and
optional channel setup.

```bash
pepe setup
```

If you prefer manual steps, use the model, agent, and channel pages. Both paths
write the same config.

<div class="note"><strong>Secrets stay out of the file.</strong> When Pepe asks for an API key it accepts a <code>${ENV_VAR}</code> reference, for example <code>${OPENROUTER_API_KEY}</code>. The reference is what gets written to <code>~/.pepe/config.json</code>. The real value is read from your environment at run time and is never stored expanded.</div>

## Docker

Prefer a container? `docker pull ghcr.io/pepe-agent/pepe` (amd64 and arm64). It needs a
volume and a dashboard password. Both are covered, along with how to give the agent
extra tools inside the container, on the [Docker page](/en/docs/docker/).

## Uninstall

Remove the binary; add the config directory to also drop every model, agent
and credential you set up.

```bash
rm ~/.local/bin/pepe
rm -rf ~/.pepe   # optional - also drops your config
```

(`~/.local/bin` is the default install dir; it's wherever `$PEPE_BIN_DIR` pointed
to if you overrode it.)
