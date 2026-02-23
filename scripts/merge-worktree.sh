#!/usr/bin/env bash
# merge-worktree.sh — merge worktree branch into main, cleanup
# Usage: merge-worktree.sh [--session NAME]
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

MAIN_BRANCH=$(detect_main_branch "$MAIN_ROOT")

echo "Merge $BRANCH → $MAIN_BRANCH"
echo ""
git -C "$MAIN_ROOT" diff --stat "$MAIN_BRANCH..$BRANCH" 2>/dev/null
echo ""
read -r -p "Merge and cleanup? [y/N] " CONFIRM
[[ ! "$CONFIRM" =~ ^[yY]$ ]] && exit 0

git -C "$MAIN_ROOT" merge --no-ff "$BRANCH" || {
    echo ""; echo "Merge failed — resolve conflicts manually."
    read -n1 -r -p ""; exit 1
}

# Kill session — tmux auto-moves clients to another session
tmux kill-session -t "=$SESSION" 2>/dev/null

# Remove worktree
[ -d "$WT" ] && git -C "$MAIN_ROOT" worktree remove "$WT" --force 2>/dev/null

# Ask about branch deletion (still in popup)
read -r -p "Delete branch $BRANCH? [Y/n] " DEL
[[ ! "$DEL" =~ ^[nN]$ ]] && git -C "$MAIN_ROOT" branch -d "$BRANCH" 2>/dev/null

# Switch to main repo session after popup closes
echo "$REPO" > /tmp/knute-switch

tmux display-message "knute: merged $BRANCH → $MAIN_BRANCH"
