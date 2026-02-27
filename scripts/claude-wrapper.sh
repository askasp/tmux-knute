#!/usr/bin/env bash
# claude-wrapper.sh — wraps claude with bell notification on exit
#
# Usage: claude-wrapper.sh [claude args...]
#
# Marks the window as a knute agent, enables monitor-bell, runs claude,
# then sends a bell and drops into a shell so the window stays open.
#
# In issue worktrees: runs Claude inside a bubblewrap sandbox with
# --dangerously-skip-permissions (safe because filesystem is restricted).

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mark this window as an active agent (used by dashboard for status detection)
tmux set-option -w @knute-agent running 2>/dev/null

# Enable monitor-bell on this window so the status bar shows activity
tmux set-option -w monitor-bell on 2>/dev/null

# If running in a worktree, restrict Claude to this directory
CLAUDE_EXTRA_ARGS=()
USE_SANDBOX=false

if [ -f .git ]; then
    WT_PATH=$(pwd)
    CLAUDE_EXTRA_ARGS+=(--append-system-prompt "IMPORTANT: You are working in a git worktree at $WT_PATH. You MUST only create and edit files within this directory. NEVER modify files in the main repository root or other worktrees. All file paths must be under $WT_PATH.")

    # If this worktree is for a GitHub issue, run fully autonomous in sandbox
    if [ -f .knute-issue ]; then
        ISSUE_NUM=$(grep '^number=' .knute-issue | cut -d= -f2-)
        ISSUE_TITLE=$(grep '^title=' .knute-issue | cut -d= -f2-)
        [ -n "$ISSUE_NUM" ] && CLAUDE_EXTRA_ARGS+=(--append-system-prompt "You are working on GitHub Issue #${ISSUE_NUM}: ${ISSUE_TITLE}. Reference this issue in your commit messages. When done, commit all changes.")

        # Skip permissions — sandbox enforces filesystem isolation
        CLAUDE_EXTRA_ARGS+=(--dangerously-skip-permissions)
        USE_SANDBOX=true
    fi
fi

# Run claude — sandboxed for issue worktrees, normal otherwise
if $USE_SANDBOX; then
    "$CURRENT_DIR/sandbox.sh" "$WT_PATH" claude "${CLAUDE_EXTRA_ARGS[@]}" "$@"
else
    claude "${CLAUDE_EXTRA_ARGS[@]}" "$@"
fi

# Mark agent as done
tmux set-option -w @knute-agent done 2>/dev/null

# Send bell to notify that claude has finished
printf '\a'

# Keep window alive so user can see output and interact
exec "$SHELL"
