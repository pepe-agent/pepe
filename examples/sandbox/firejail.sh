#!/usr/bin/env sh
# Pepe sandbox wrapper for Linux using firejail (namespaces, lightweight).
# Confines filesystem writes to the agent's workspace; keeps networking.
#
#   apt install firejail
#   Pepe.Config.set_sandbox("/abs/path/examples/sandbox/firejail.sh")
set -eu

exec firejail --quiet \
  --private="$PEPE_SANDBOX_CWD" \
  --whitelist="$PEPE_SANDBOX_CWD" \
  --caps.drop=all --nonewprivs --noroot \
  -- "$@"
