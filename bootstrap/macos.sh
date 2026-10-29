#!/usr/bin/env bash
#
# bootstrap/macos.sh — macOS setup for this dotfiles repo.
#
#     ./bootstrap/macos.sh
#
# Package policy mirrors bootstrap/linux.sh: Homebrew for GUI apps (~/.Brewfile),
# mise for interactive CLI tools and runtimes (mise/config.toml).
#
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

STOW_PACKAGES="git git-darwin fish starship mise zed homebrew"

require_user

[ "$(uname -s)" = Darwin ] || die "This script targets macOS."

command -v brew >/dev/null 2>&1 || die "Homebrew is required: https://brew.sh"

# --- 1. stow -----------------------------------------------------------------
if ! command -v stow >/dev/null 2>&1; then
  log "Installing stow"
  brew install stow
fi

# --- 2. mise -----------------------------------------------------------------
if ! command -v mise >/dev/null 2>&1; then
  log "Installing mise"
  brew install mise
fi

# --- 3. dotfiles -------------------------------------------------------------
for pkg in $STOW_PACKAGES; do
  log "Stowing $pkg"
  stow_package "$pkg"
done

# --- 4. Homebrew bundle ------------------------------------------------------
if [ -f "$HOME/.Brewfile" ]; then
  log "brew bundle --global"
  brew bundle --global --verbose
else
  warn "No ~/.Brewfile (stow the 'homebrew' package) — skipping brew bundle"
fi

# --- 5. fish plugins ---------------------------------------------------------
install_fish_plugins

# --- 6. runtimes + CLI tools declared in mise/config.toml --------------------
log "mise install (Node LTS, Python, and the CLI tools)"
mise install

log "Done."
if [ -d "$BACKUP_DIR" ]; then
  log "Backups: $BACKUP_DIR"
fi
