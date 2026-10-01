if status is-interactive
    # Commands to run in interactive sessions can go here
    set -g fish_greeting ""

    if type -q starship
        starship init fish | source
    end

    if type -q nvim
        alias vim nvim
        set -gx EDITOR nvim
        set -gx VISUAL nvim
    end

    if type -q bat
        alias cat 'bat --paging=never --style=plain'
    else if type -q batcat
        alias cat 'batcat --paging=never --style=plain'
    end

    if type -q zoxide
        zoxide init fish | source
    end
end

if type -q vfox
    vfox activate fish | source
end

# Keep the universal fish_variables file out of chezmoi; this is portable
# across users and machines and does not persist an absolute home path.
set -gx PATH "$HOME/bin" "$HOME/.local/bin" $PATH
