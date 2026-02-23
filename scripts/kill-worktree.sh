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

# Kill the session — tmux auto-moves clients to another session
tmux kill-session -t "=$SESSION" 2>/dev/null

# Remove worktree
[ -d "$WT" ] && git -C "$MAIN_ROOT" worktree remove "$WT" --force 2>/dev/null

tmux display-message "knute: killed $SESSION"
