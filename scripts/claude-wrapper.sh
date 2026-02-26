#!/usr/bin/env bash
# claude-wrapper.sh — wraps claude with bell notification on exit
#
# Usage: claude-wrapper.sh [claude args...]
#
# Marks the window as a knute agent, enables monitor-bell, runs claude,
# then sends a bell and drops into a shell so the window stays open.

# Mark this window as an active agent (used by dashboard for status detection)
tmux set-option -w @knute-agent running 2>/dev/null

# Enable monitor-bell on this window so the status bar shows activity
tmux set-option -w monitor-bell on 2>/dev/null

# If running in a worktree, restrict Claude to this directory
CLAUDE_EXTRA_ARGS=()
if [ -f .git ]; then
    WT_PATH=$(pwd)
    CLAUDE_EXTRA_ARGS+=(--append-system-prompt "IMPORTANT: You are working in a git worktree at $WT_PATH. You MUST only create and edit files within this directory. NEVER modify files in the main repository root or other worktrees. All file paths must be under $WT_PATH.")
fi

# Run claude with all passed arguments
claude "${CLAUDE_EXTRA_ARGS[@]}" "$@"

# Mark agent as done
tmux set-option -w @knute-agent done 2>/dev/null

# Send bell to notify that claude has finished
printf '\a'

# Keep window alive so user can see output and interact
exec "$SHELL"
