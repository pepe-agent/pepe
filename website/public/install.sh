#!/bin/sh
# Pepe installer. Downloads the self-contained `pepe` binary for your platform
# from the latest GitHub release. Nothing else needs to be installed.
#
#     curl -fsSL https://pepe-agent.com/install.sh | sh
#
# Overrides (env vars):
#   PEPE_REPO      GitHub repo to pull from      (default pepe-agent/pepe)
#   PEPE_VERSION   release tag to install         (default latest)
#   PEPE_BIN_DIR   where to place the binary       (default ~/.local/bin)

set -eu

REPO="${PEPE_REPO:-pepe-agent/pepe}"
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

# If the install dir isn't on PATH, prepend it to whichever shell rc files
# exist (so new shells pick it up automatically), falling back to creating
# ~/.bashrc if neither is present.
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    path_line="export PATH=\"$BIN_DIR:\$PATH\""
    written=""
    first_rc=""
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      if [ -f "$rc" ]; then
        if ! grep -qxF "$path_line" "$rc" 2>/dev/null; then
          rc_tmp="$(mktemp)"
          { printf '%s\n' "$path_line"; cat "$rc"; } >"$rc_tmp"
          mv "$rc_tmp" "$rc"
        fi
        written="$written $rc"
        [ -z "$first_rc" ] && first_rc="$rc"
      fi
    done
    if [ -z "$written" ]; then
      printf '%s\n' "$path_line" >>"$HOME/.bashrc"
      written=" $HOME/.bashrc"
      first_rc="$HOME/.bashrc"
    fi

    echo
    ok "Added $BIN_DIR to PATH in:$written"
    echo
    info "Open a new terminal, or run:  . $first_rc"
    ;;
esac

echo
ok "Done. Next:  pepe setup"
echo
info "Uninstall anytime:  rm $BIN_DIR/pepe   (and rm -rf ~/.pepe to also drop your config)"
