#!/usr/bin/env sh
# Pepe sandbox wrapper: run the agent's command inside an ephemeral container.
# Only the agent's working dir is mounted, so the rest of the host FS is invisible.
# Portable: works on Linux, macOS and Windows wherever Docker/Podman is installed.
#
#   Pepe.Config.set_sandbox("/abs/path/examples/sandbox/docker.sh")
#
# Tune with env vars: PEPE_SANDBOX_IMAGE, PEPE_SANDBOX_NET (bridge|none),
# PEPE_SANDBOX_MEM, PEPE_SANDBOX_CPUS.
set -eu

IMAGE="${PEPE_SANDBOX_IMAGE:-python:3.12-slim}"
NET="${PEPE_SANDBOX_NET:-bridge}"
MEM="${PEPE_SANDBOX_MEM:-512m}"
CPUS="${PEPE_SANDBOX_CPUS:-1}"
RUNTIME="${PEPE_SANDBOX_RUNTIME:-docker}"

exec "$RUNTIME" run --rm \
  --network "$NET" \
  --memory "$MEM" --cpus "$CPUS" \
  --pids-limit 256 \
  -v "$PEPE_SANDBOX_CWD:$PEPE_SANDBOX_CWD" \
  -w "$PEPE_SANDBOX_CWD" \
  "$IMAGE" "$@"
