#!/bin/sh
# Bootstrap a machine from this repo.
#
# Layers (see README):
#   - mise  -> language runtimes + portable CLI, identical on macOS and Ubuntu
#   - brew  -> macOS GUI apps, casks and extensions (~/.Brewfile, stowed)
#   - apt   -> Ubuntu system packages (ubuntu/apt-packages.txt, repo-internal)
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TARGET="$HOME"
STOW_PACKAGES="git fish mise starship zed homebrew"

log() { printf '\n==> %s\n' "$*"; }

install_stow() {
  if command -v stow >/dev/null 2>&1; then
    return
  fi
  log "installing stow"
  case "$(uname -s)" in
    Darwin) brew install stow ;;
    Linux) sudo apt-get update && sudo apt-get install -y stow ;;
  esac
}

link_dotfiles() {
  log "stowing packages: $STOW_PACKAGES"
  cd "$REPO_DIR"
  # Package dirs that were not cloned yet would abort the run.
  for pkg in $STOW_PACKAGES; do
    [ -d "$pkg" ] || continue
    stow -R -t "$TARGET" "$pkg"
  done
}

platform_packages() {
  case "$(uname -s)" in
    Darwin)
      log "brew bundle --global"
      brew bundle --global --verbose
      ;;
    Linux)
      log "installing apt manifest"
      grep -vE '^[[:space:]]*(#|$)' "$REPO_DIR/ubuntu/apt-packages.txt" |
        xargs sudo apt-get install -y
      ;;
    *)
      echo "unsupported platform: $(uname -s)" >&2
      exit 1
      ;;
  esac
}

install_stow
link_dotfiles
platform_packages

# Requires shell activation to be in place: on macOS Homebrew ships
# share/fish/vendor_conf.d/mise-activate.fish, on Ubuntu config.fish does it.
log "mise install"
if command -v mise >/dev/null 2>&1; then
  mise install
else
  echo "mise is not on PATH; skipping (install it, then run 'mise install')" >&2
fi
