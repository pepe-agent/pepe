#!/usr/bin/env sh
# Pepe sandbox wrapper for macOS using sandbox-exec (Seatbelt).
# Denies filesystem writes outside the agent's workspace and the temp dirs.
# Note: sandbox-exec is deprecated by Apple but still functional; it's a soft jail.
#
#   Pepe.Config.set_sandbox("/abs/path/examples/sandbox/macos-sandbox.sh")
set -eu

PROFILE="(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath \"$PEPE_SANDBOX_CWD\")
  (subpath \"/private/tmp\")
  (subpath \"/private/var/folders\"))"

exec sandbox-exec -p "$PROFILE" "$@"
