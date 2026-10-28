if status is-interactive
    # Commands to run in interactive sessions can go here
end

# User-local binaries. mise installs itself here, so this has to come first.
if test -d "$HOME/.local/bin"; and not contains "$HOME/.local/bin" $PATH
    set -gx PATH "$HOME/.local/bin" $PATH
end

# mise: language runtimes and CLI tools (bat, fd, rg, fzf, starship, ...).
# Interactive shells get full activation; non-interactive ones get just the
# shims, so `ssh ubuntu 'rg foo'` and scripts still find the tools.
if type -q mise
    if status is-interactive
        mise activate fish | source
    else if test -d "$HOME/.local/share/mise/shims"
        set -gx PATH "$HOME/.local/share/mise/shims" $PATH
    end
end

# Guarded so a fresh machine doesn't spam errors before the bootstrap runs.
if type -q starship
    starship init fish | source
end
