status is-login; and pyenv init --path | source

if status is-interactive
    # Commands to run in interactive sessions can go here
    status is-interactive; and pyenv init - | source
end

# set -g theme_color_scheme light
# set -g theme_powerline_fonts no
# set -g theme_nerd_fonts yes
# set -g fish_prompt_pwd_dir_length 3

starship init fish | source