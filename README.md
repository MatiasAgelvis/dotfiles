# dotfiles

Managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Layout

```
dotfiles/
├── git/ fish/ mise/ starship/ ...   # stow packages, paths mirror $HOME
├── bootstrap/
│   ├── lib.sh                       # shared helpers (stow, fisher, backups)
│   ├── linux.sh                     # Ubuntu/Debian
│   └── macos.sh                     # macOS
├── packages/
│   └── apt-ubuntu.txt               # apt manifest consumed by linux.sh
├── docs/
│   └── server.md                    # notes for the homelab box
└── README.md
```

**Package policy:** system packages come from apt (Linux) or Homebrew (macOS);
interactive CLI tools and runtimes come from **mise**, so both machines run the
same versions. Anything scripts or `sudo` must find stays in apt.

## Packages

| Package | Files |
|---|---|
| `git` | `~/.gitconfig` |
| `git-darwin` | `~/.gitconfig.darwin` (macOS only: Kaleidoscope, Credential Manager) |
| `fish` | `~/.config/fish/config.fish` |
| `mise` | `~/.config/mise/config.toml` (runtimes + CLI tools) |
| `starship` | `~/.config/starship.toml` |
| `zed` | `~/.config/zed/settings.json`, `keymap.json` (macOS only) |
| `homebrew` | `~/.Brewfile` (macOS only, not committed yet) |

## Quick reference

### Add a new file to track

```sh
cd ~/documents/dev/dotfiles
mkdir <package>
cp ~/<path-to-file> <package>/<path>
stow -t ~ <package>
```

**Example** — add `~/.config/gh/config.yml`:

```sh
cd ~/documents/dev/dotfiles
mkdir -p gh/.config/gh
cp ~/.config/gh/config.yml gh/.config/gh/
stow -t ~ gh
```

Or with `--adopt` (moves existing file into stow tree):

```sh
cd ~/documents/dev/dotfiles
mkdir gh
touch gh/.config/gh/config.yml
stow --adopt -t ~ gh
```

### Edit a tracked file

```sh
# Via the symlink (edits the real file)
zed ~/.gitconfig

# Or the source file directly
zed ~/documents/dev/dotfiles/git/.gitconfig
```

### Commit changes

```sh
cd ~/documents/dev/dotfiles
git add -A
git commit -m "feat(git): add diff tool config"
git push
```

### Unstow / remove symlinks

```sh
cd ~/documents/dev/dotfiles
stow -D -t ~ <package>
```

### Restow (reapply all symlinks)

```sh
cd ~/documents/dev/dotfiles
stow -R -t ~ git git-darwin fish mise starship zed homebrew
```

### Setup on a new machine

Both scripts are idempotent and back up conflicting files to
`~/.dotfiles-backup/<timestamp>/` instead of deleting them.

**Linux (Ubuntu/Debian)**

```sh
git clone https://github.com/MatiasAgelvis/dotfiles ~/dotfiles
~/dotfiles/bootstrap/linux.sh           # apt, mise, dotfiles, fish plugins
~/dotfiles/bootstrap/linux.sh --chsh    # ...plus fish as the login shell
```

**macOS**

```sh
brew install stow
git clone https://github.com/MatiasAgelvis/dotfiles ~/documents/dev/dotfiles
~/documents/dev/dotfiles/bootstrap/macos.sh
```

`zed` (GUI editor), `git-darwin`, and `homebrew` are only stowed on macOS. On
servers, CLI tools come from mise; see `docs/server.md` for machine notes.

## Stow rules

- The file path inside a package mirrors the path from `$HOME`
- Always use `-t ~` to target the home directory (stow's default target is the parent — `~/documents/dev/`)
- Run all stow commands from the repo root (`~/dotfiles` on Linux, `~/documents/dev/dotfiles` on macOS)

## What's NOT tracked (by choice)

- `~/.zshrc`, `~/.zprofile`, `~/.p10k.zsh` — legacy ZSH config
- `~/.config/raycast-x/` — contains access tokens
- `~/.config/karabiner/` — contains device serials
- VS Code — uses built-in Settings Sync
- Fisher-managed files — regenerated from `fish_plugins`

## How stow works

```
~/documents/dev/dotfiles/
└── fish/
    └── .config/
        └── fish/
            └── config.fish  →  ~/.config/fish/config.fish
```

The package name is the root. Everything inside it mirrors the path from `$HOME`.
