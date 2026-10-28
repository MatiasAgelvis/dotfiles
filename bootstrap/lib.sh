#!/usr/bin/env bash
#
# bootstrap/lib.sh — helpers shared by bootstrap/linux.sh and bootstrap/macos.sh.
# Source it, don't run it.
#
# Deliberately bash-3.2 compatible (macOS ships bash 3.2) and free of GNU-only
# tools like `find -printf`.
#
set -uo pipefail

DOTFILES=${DOTFILES:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=${BACKUP_DIR:-$HOME/.dotfiles-backup/$STAMP}

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() {
  warn "$*"
  exit 1
}

require_user() {
  [ "$(id -u)" -ne 0 ] || die "Run as your user, not with sudo — stow and fisher must own these files."
}

# Relative paths of every file inside a stow package.
package_files() {
  (cd "$DOTFILES/$1" && find . -type f | sed 's|^\./||')
}

# Move any real file that would block a symlink out of the way, then stow.
# Existing symlinks (i.e. already stowed) are left alone, so re-runs are safe.
stow_package() {
  local pkg=$1 rel target
  if [ ! -d "$DOTFILES/$pkg" ]; then
    warn "skipping missing package: $pkg"
    return 0
  fi
  while IFS= read -r rel; do
    target="$HOME/$rel"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
      mv "$target" "$BACKUP_DIR/$rel"
      log "Backed up ~/$rel -> $BACKUP_DIR/$rel"
    fi
  done < <(package_files "$pkg")
  (cd "$DOTFILES" && stow --restow --target="$HOME" "$pkg")
}

# Fisher itself, then whatever fish/.config/fish/fish_plugins declares.
install_fish_plugins() {
  local fisher=$HOME/.config/fish/functions/fisher.fish
  command -v fish >/dev/null 2>&1 || {
    warn "fish not installed; skipping fisher"
    return 0
  }
  if [ ! -f "$fisher" ]; then
    log "Installing fisher"
    fish -c 'curl -fsSL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher'
  fi
  if [ -f "$HOME/.config/fish/fish_plugins" ]; then
    log "Restoring fish plugins"
    fish -c 'fisher update'
  fi
}

# mise installs its binary into ~/.local/bin on Linux; make it usable now.
ensure_mise_on_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
}

install_mise() {
  if command -v mise >/dev/null 2>&1; then
    log "mise already installed: $(mise --version 2>/dev/null | head -1)"
    return 0
  fi
  log "Installing mise"
  curl -fsSL https://mise.run | sh
  ensure_mise_on_path
}

install_stow() {
  command -v stow >/dev/null 2>&1 || die "stow is missing — install it, then re-run"
}
