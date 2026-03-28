#!/bin/sh
# Pepe installer. Downloads the self-contained `pepe` binary for your platform
# from the latest GitHub release. Nothing else needs to be installed.
#
#     curl -fsSL https://pepe-agent.com/install.sh | sh
#
# Overrides (env vars):
#   PEPE_REPO      GitHub repo to pull from      (default jhonathas/pepe)
#   PEPE_VERSION   release tag to install         (default latest)
#   PEPE_BIN_DIR   where to place the binary       (default ~/.local/bin)

set -eu

REPO="${PEPE_REPO:-jhonathas/pepe}"
VERSION="${PEPE_VERSION:-latest}"
BIN_DIR="${PEPE_BIN_DIR:-$HOME/.local/bin}"

info() { printf '\033[0;36m%s\033[0m\n' "$1"; }
ok()   { printf '\033[0;32m%s\033[0m\n' "$1"; }
err()  { printf '\033[0;31m%s\033[0m\n' "$1" >&2; }

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Darwin)
    case "$arch" in
      arm64|aarch64) target="macos_arm" ;;
      x86_64|amd64)  target="macos_x86" ;;
      *) err "Unsupported macOS architecture: $arch"; exit 1 ;;
    esac
    ;;
  Linux)
    case "$arch" in
      aarch64|arm64) target="linux_arm" ;;
      x86_64|amd64)  target="linux_x86" ;;
      *) err "Unsupported Linux architecture: $arch"; exit 1 ;;
    esac
    ;;
  *)
    err "Unsupported OS: $os."
    err "On Windows, download pepe_windows.exe from https://github.com/$REPO/releases"
    exit 1
    ;;
esac

asset="pepe_${target}"
if [ "$VERSION" = "latest" ]; then
  url="https://github.com/$REPO/releases/latest/download/$asset"
else
  url="https://github.com/$REPO/releases/download/$VERSION/$asset"
fi

info "Installing pepe ($target) from $REPO..."

mkdir -p "$BIN_DIR"
tmp="$(mktemp)"
if ! curl -fSL --progress-bar "$url" -o "$tmp"; then
  err "Download failed: $url"
  err "No release yet? See https://github.com/$REPO/releases"
  rm -f "$tmp"
  exit 1
fi

chmod +x "$tmp"
mv "$tmp" "$BIN_DIR/pepe"
ok "Installed pepe to $BIN_DIR/pepe"

# Nudge the user if the install dir is not on their PATH.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    info "Add $BIN_DIR to your PATH, e.g.:"
    echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.profile && . ~/.profile"
    ;;
esac

echo
ok "Done. Next:  pepe setup"
