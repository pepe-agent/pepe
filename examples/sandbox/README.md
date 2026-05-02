# Sandbox wrappers

Pepe's `bash` and `run_script` tools can run through an optional **sandbox wrapper**
so the agent executes isolated instead of straight on the host. Two layers:

- **Guardrails (on by default, zero config):** Pepe refuses a few catastrophic,
  never-legitimate commands (wiping the disk, `mkfs`, fork bombs, powering off).
  It's a thin net against accidents/injection, **not** a security boundary.
- **Isolation (opt-in, strong):** point Pepe at a wrapper program below.

There is no zero-config, cross-platform *true* sandbox - real isolation always needs
an OS feature or an external tool. Pick the one your host supports.

## Enable

```elixir
Pepe.Config.set_sandbox("/absolute/path/to/examples/sandbox/docker.sh")
```

The wrapper is invoked as `wrapper <program> <args...>` with the agent's working
directory in `$PEPE_SANDBOX_CWD`. It must run that command isolated and exit with its
status.

## Which wrapper?

| Host | Options |
|------|---------|
| **Linux** | `firejail.sh` / `bwrap` (light, native) · `docker.sh` (strong) |
| **macOS** | `macos-sandbox.sh` (`sandbox-exec`, native) · `docker.sh` (Docker Desktop) |
| **Windows** | `docker.sh` via Docker Desktop / WSL (no light native option) |

`docker.sh` is the portable common denominator: if Docker/Podman is installed, the
same wrapper works on Linux, macOS and Windows. Tune network/mounts to your policy
(e.g. keep the network on so the agent can reach a database, but mount only the
workspace so it can't touch the rest of the host).
