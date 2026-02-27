#!/usr/bin/env bash
# sandbox.sh — run a command inside a bubblewrap sandbox
#
# Usage: sandbox.sh WORKTREE_PATH COMMAND [ARGS...]
#
# Filesystem access:
#   read-write: worktree dir, /tmp, ~/.claude (auth/config), ~/.gitconfig
#   read-only:  /usr, /lib, /lib64, /bin, /sbin, /etc, system tools
#   blocked:    everything else (home dir, other repos, other worktrees)
#
# Network: allowed (Claude needs API access)
# PID/IPC: isolated

WORKTREE="$1"
shift

if [ -z "$WORKTREE" ] || [ $# -eq 0 ]; then
    echo "Usage: sandbox.sh WORKTREE_PATH COMMAND [ARGS...]"
    exit 1
fi

if ! command -v bwrap &>/dev/null; then
    echo "bubblewrap not installed. Install: sudo pacman -S bubblewrap"
    echo "Falling back to unsandboxed execution."
    cd "$WORKTREE" && exec "$@"
fi

# Resolve the main repo root (parent of .worktrees/)
MAIN_REPO=$(git -C "$WORKTREE" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')

BWRAP_ARGS=(
    # System directories (read-only)
    --ro-bind /usr /usr
    --ro-bind /lib /lib
    --ro-bind /lib64 /lib64
    --ro-bind /bin /bin
    --ro-bind /sbin /sbin
    --ro-bind /etc /etc

    # Proc, dev, tmp
    --proc /proc
    --dev /dev
    --tmpfs /tmp

    # Worktree directory (read-write) — this is the agent's workspace
    --bind "$WORKTREE" "$WORKTREE"

    # Main repo .git dir (read-only for git operations like log, diff)
    # Worktrees reference the main repo's .git via the .git file
    --ro-bind "$MAIN_REPO/.git" "$MAIN_REPO/.git"

    # Claude config and credentials (read-write for session state)
    --bind "$HOME/.claude" "$HOME/.claude"

    # Claude binary and data
    --ro-bind "$HOME/.local" "$HOME/.local"

    # Git config (read-only)
    --ro-bind-try "$HOME/.gitconfig" "$HOME/.gitconfig"
    --ro-bind-try "$HOME/.config/git" "$HOME/.config/git"

    # SSH keys for git push (read-only)
    --ro-bind-try "$HOME/.ssh" "$HOME/.ssh"

    # GPG for commit signing (read-only)
    --ro-bind-try "$HOME/.gnupg" "$HOME/.gnupg"

    # gh CLI config (read-only — for issue comments)
    --ro-bind-try "$HOME/.config/gh" "$HOME/.config/gh"

    # tmux socket (needed for tmux set-option from inside sandbox)
    --ro-bind-try /tmp/tmux-$(id -u) /tmp/tmux-$(id -u)

    # Knute temp files (read-write for inter-process communication)
    --bind-try /tmp/knute-session /tmp/knute-session
    --bind-try /tmp/knute-switch /tmp/knute-switch
    --bind-try /tmp/knute-window /tmp/knute-window

    # DNS resolution
    --ro-bind /etc/resolv.conf /etc/resolv.conf

    # Keep same UID/GID
    --unshare-pid
    --unshare-ipc

    # Set working directory
    --chdir "$WORKTREE"

    # Environment
    --setenv HOME "$HOME"
    --setenv PATH "$PATH"
    --setenv TERM "$TERM"
    --setenv SHELL "$SHELL"
    --setenv USER "$USER"
    --setenv LANG "${LANG:-en_US.UTF-8}"
)

# Add XDG dirs if set
[ -n "$XDG_CONFIG_HOME" ] && BWRAP_ARGS+=(--setenv XDG_CONFIG_HOME "$XDG_CONFIG_HOME")
[ -n "$XDG_DATA_HOME" ] && BWRAP_ARGS+=(--setenv XDG_DATA_HOME "$XDG_DATA_HOME")
[ -n "$XDG_RUNTIME_DIR" ] && BWRAP_ARGS+=(
    --bind-try "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR"
    --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR"
)

exec bwrap "${BWRAP_ARGS[@]}" -- "$@"
