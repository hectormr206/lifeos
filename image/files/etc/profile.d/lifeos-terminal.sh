#!/bin/sh
# LifeOS terminal defaults for interactive POSIX/Bash shells.
# Keep this lightweight and safe when commands are missing.

if [ -n "${LIFEOS_TERMINAL_INIT_DONE:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

export LIFEOS_TERMINAL_INIT_DONE=1

if [ -z "${EDITOR:-}" ] && command -v nvim >/dev/null 2>&1; then
    export EDITOR="nvim"
fi

if [ -z "${VISUAL:-}" ] && [ -n "${EDITOR:-}" ]; then
    export VISUAL="${EDITOR}"
fi

if [ -z "${PAGER:-}" ] && command -v bat >/dev/null 2>&1; then
    export PAGER="bat"
fi

if command -v eza >/dev/null 2>&1; then
    alias ls='eza --icons=auto'
    alias ll='eza -lah --icons=auto --group-directories-first'
    alias lt='eza -T --icons=auto --level=2'
fi

if command -v btop >/dev/null 2>&1; then
    alias top='btop'
fi

if command -v nvim >/dev/null 2>&1; then
    alias v='nvim'
fi

if command -v tmux >/dev/null 2>&1; then
    alias t='tmux'
fi

if command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fd --type f --strip-cwd-prefix'
    export FZF_CTRL_T_COMMAND='fd --type f --strip-cwd-prefix'
fi

if [ -n "${BASH_VERSION:-}" ]; then
    if command -v fzf >/dev/null 2>&1; then
        eval "$(fzf --bash)"
    fi

    if command -v zoxide >/dev/null 2>&1; then
        eval "$(zoxide init bash)"
    fi

    if command -v atuin >/dev/null 2>&1; then
        eval "$(atuin init bash)"
    fi

    if command -v direnv >/dev/null 2>&1; then
        eval "$(direnv hook bash)"
    fi
fi
