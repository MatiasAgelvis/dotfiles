#!/usr/bin/env bash
#
# bootstrap/linux.sh — reproduce this dotfiles setup on a Debian/Ubuntu machine.
#
# Run as your normal user (it calls sudo itself for apt):
#
#     ./bootstrap/linux.sh            # packages + stow + fisher
#     ./bootstrap/linux.sh --chsh     # ...and make fish your login shell
#
# Idempotent: re-running is safe. Real files that would be overwritten by stow
# are moved to ~/.dotfiles-backup/<timestamp>/ first, never deleted.
#
set -euo pipefail

DOTFILES=${DOTFILES:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=${BACKUP_DIR:-$HOME/.dotfiles-backup/$STAMP}

# Packages stowed on Linux. `zed` is GUI-only and `mise` is opt-in; see README.
STOW_PACKAGES=(fish starship git)

# Debian ships these binaries under different names than upstream expects.
APT_PACKAGES=(git stow starship fzf bat eza zoxide ripgrep fd-find fish curl)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

if [[ $EUID -eq 0 ]]; then
  warn "Run this as your user, not with sudo — stow and fisher must own your files."
  exit 1
fi

# --- 1. apt packages ---------------------------------------------------------
missing=()
for pkg in "${APT_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' \
    || missing+=("$pkg")
done

if ((${#missing[@]})); then
  log "Installing: ${missing[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends "${missing[@]}"
else
  log "All apt packages already installed"
fi

# --- 2. Debian binary shims --------------------------------------------------
# batcat -> bat, fdfind -> fd. User-level, so no sudo and no system changes.
mkdir -p "$HOME/.local/bin"
for pair in batcat:bat fdfind:fd; do
  src=${pair%%:*}
  dst=${pair##*:}
  if command -v "$src" >/dev/null 2>&1 && [[ ! -e $HOME/.local/bin/$dst ]]; then
    ln -s "$(command -v "$src")" "$HOME/.local/bin/$dst"
    log "Linked ~/.local/bin/$dst -> $(command -v "$src")"
  fi
done

# --- 3. stow -----------------------------------------------------------------
# Move any real file that would block a symlink into the backup dir.
backup_conflicts() {
  local pkg=$1 rel target
  while IFS= read -r rel; do
    target=$HOME/$rel
    if [[ -e $target && ! -L $target ]]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
      mv "$target" "$BACKUP_DIR/$rel"
      log "Backed up ~/$rel -> $BACKUP_DIR/$rel"
    fi
  done < <(cd "$DOTFILES/$pkg" && find . -type f -printf '%P\n')
}

log "Stowing from $DOTFILES: ${STOW_PACKAGES[*]}"
for pkg in "${STOW_PACKAGES[@]}"; do
  [[ -d $DOTFILES/$pkg ]] || { warn "No such package: $pkg"; exit 1; }
  backup_conflicts "$pkg"
  stow --dir="$DOTFILES" --target="$HOME" --restow "$pkg"
done

# --- 4. fisher + plugins -----------------------------------------------------
FISHER=~/.config/fish/functions/fisher.fish
if [[ ! -f $FISHER ]]; then
  log "Installing fisher"
  fish -c 'curl -fsSL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher'
fi

if [[ -f $DOTFILES/fish/.config/fish/fish_plugins ]]; then
  log "Restoring fish plugins from fish_plugins"
  fish -c 'fisher update'
fi

# --- 5. optional: login shell ------------------------------------------------
if [[ ${1:-} == --chsh ]]; then
  current=$(getent passwd "$USER" | cut -d: -f7)
  fish_bin=$(command -v fish)
  if [[ $current != "$fish_bin" ]]; then
    log "Changing login shell: $current -> $fish_bin"
    chsh -s "$fish_bin"
  else
    log "Login shell already $fish_bin"
  fi
fi

log "Done."
[[ -d $BACKUP_DIR ]] && log "Backups: $BACKUP_DIR"
log "Open a new terminal, or run: fish"
