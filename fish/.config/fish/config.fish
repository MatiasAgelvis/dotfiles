if status is-interactive
    # Commands to run in interactive sessions can go here
end

# User-local binaries first (Debian renames bat -> batcat, fd -> fdfind;
# bootstrap/linux.sh symlinks them into ~/.local/bin).
if test -d "$HOME/.local/bin"; and not contains "$HOME/.local/bin" $PATH
    set -gx PATH "$HOME/.local/bin" $PATH
end

starship init fish | source
