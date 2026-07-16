# dotfiles

Managed with [GNU Stow](https://www.gnu.org/software/stow/).

## Packages

| Package | Files |
|---|---|
| `git` | `~/.gitconfig` |
| `fish` | `~/.config/fish/config.fish` |
| `mise` | `~/.config/mise/config.toml` |
| `starship` | `~/.config/starship.toml` |
| `zed` | `~/.config/zed/settings.json`, `keymap.json` |

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
stow -R -t ~ git fish mise starship zed
```

### Setup on a new machine

```sh
brew install stow
git clone https://github.com/MatiasAgelvis/dotfiles ~/documents/dev/dotfiles
cd ~/documents/dev/dotfiles
stow -t ~ git fish mise starship zed
# If using fisher:
fisher install jethrokuan/z patrickf1/fzf.fish
```

## Stow rules

- The file path inside a package mirrors the path from `$HOME`
- Always use `-t ~` to target the home directory (stow's default target is the parent — `~/documents/dev/`)
- Run all stow commands from `~/documents/dev/dotfiles`

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
