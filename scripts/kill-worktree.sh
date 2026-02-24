#!/usr/bin/env bash
# kill-worktree.sh — kill worktree session and remove worktree
# Usage: kill-worktree.sh [--session NAME]
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

parse_session_arg "$@"

if [[ "$SESSION" != */* ]]; then
    echo "Not a worktree session ($SESSION)"
    read -n1 -r -p ""; exit 1
fi

REPO="${SESSION%%/*}"
BRANCH="${SESSION#*/}"
WT=$(session_worktree_path "$SESSION")
MAIN_ROOT="${WT%/$WORKTREE_DIR/$BRANCH}"

echo "Kill: $SESSION"
[ -d "$WT" ] && echo "Path: $WT"
echo ""
read -r -p "Kill session and remove worktree? [y/N] " CONFIRM
[[ ! "$CONFIRM" =~ ^[yY]$ ]] && exit 0

# If killing the session we're in, switch client to another session first
# so the dashboard popup doesn't die with it
CURRENT_CLIENT_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
if [ "$CURRENT_CLIENT_SESSION" = "$SESSION" ]; then
    OTHER=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v "^${SESSION}$" | head -1)
    [ -n "$OTHER" ] && tmux switch-client -t "=$OTHER"
fi

tmux kill-session -t "=$SESSION" 2>/dev/null

# Remove worktree
[ -d "$WT" ] && git -C "$MAIN_ROOT" worktree remove "$WT" --force 2>/dev/null

tmux display-message "knute: killed $SESSION"
