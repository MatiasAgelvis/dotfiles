#!/usr/bin/env bash
#
# bootstrap/linux.sh — Ubuntu/Debian setup for this dotfiles repo.
#
#     ./bootstrap/linux.sh            # packages, mise, dotfiles, fish plugins
#     ./bootstrap/linux.sh --chsh     # ...and make fish the login shell
#
# Run as your normal user; it calls sudo for apt itself. Idempotent, and real
# files that would be replaced by a symlink are moved to ~/.dotfiles-backup/.
#
# Package policy:
#   apt  -> system + login-shell packages (packages/apt-ubuntu.txt)
#   mise -> interactive CLI tools, so macOS and Ubuntu match (mise/config.toml)
#
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# `git-darwin` is macOS-only; `zed` is a GUI editor; `homebrew` is macOS-only.
STOW_PACKAGES="git fish starship mise"
APT_MANIFEST=$DOTFILES/packages/apt-ubuntu.txt

require_user

command -v apt-get >/dev/null 2>&1 || die "This script targets Debian/Ubuntu (no apt-get found)."

# --- 1. system packages ------------------------------------------------------
if [ ! -f "$APT_MANIFEST" ]; then
  die "Missing package manifest: $APT_MANIFEST"
fi

log "Installing system packages from packages/apt-ubuntu.txt"
sudo apt-get update -qq
# shellcheck disable=SC2046
sudo apt-get install -y --no-install-recommends $(grep -vE '^[[:space:]]*(#|$)' "$APT_MANIFEST")

# --- 2. mise (CLI tools + runtimes) ------------------------------------------
install_mise

# --- 3. dotfiles -------------------------------------------------------------
install_stow
for pkg in $STOW_PACKAGES; do
  log "Stowing $pkg"
  stow_package "$pkg"
done

# --- 4. fish plugins ---------------------------------------------------------
install_fish_plugins

# --- 5. runtimes + CLI tools declared in mise/config.toml --------------------
log "mise install (Node LTS, Python, and the CLI tools)"
mise install

# --- 6. optional: login shell ------------------------------------------------
if [ "${1:-}" = "--chsh" ]; then
  current=$(getent passwd "$USER" | cut -d: -f7)
  fish_bin=$(command -v fish)
  if [ "$current" != "$fish_bin" ]; then
    log "Changing login shell: $current -> $fish_bin"
    chsh -s "$fish_bin"
  else
    log "Login shell already $fish_bin"
  fi
fi

log "Done."
if [ -d "$BACKUP_DIR" ]; then
  log "Backups: $BACKUP_DIR"
fi
log "Open a new terminal, or run: fish"
