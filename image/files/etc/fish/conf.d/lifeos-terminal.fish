# LifeOS terminal defaults for interactive fish shells.

status is-interactive; or return

if set -q LIFEOS_TERMINAL_INIT_DONE
    return
end
set -gx LIFEOS_TERMINAL_INIT_DONE 1

if not set -q EDITOR
    if command -sq nvim
        set -gx EDITOR nvim
    end
end

if not set -q VISUAL
    if set -q EDITOR
        set -gx VISUAL $EDITOR
    end
end

if not set -q PAGER
    if command -sq bat
        set -gx PAGER bat
    end
end

if command -sq eza
    alias ls 'eza --icons=auto'
    alias ll 'eza -lah --icons=auto --group-directories-first'
    alias lt 'eza -T --icons=auto --level=2'
end

if command -sq btop
    alias top btop
end

if command -sq nvim
    alias v nvim
end

if command -sq tmux
    alias t tmux
end

if command -sq fd
    set -gx FZF_DEFAULT_COMMAND 'fd --type f --strip-cwd-prefix'
    set -gx FZF_CTRL_T_COMMAND 'fd --type f --strip-cwd-prefix'
end

if command -sq fzf
    fzf --fish | source
end

if command -sq zoxide
    zoxide init fish | source
end

if command -sq atuin
    atuin init fish | source
end

if command -sq direnv
    direnv hook fish | source
end
