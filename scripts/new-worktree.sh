#!/usr/bin/env bash
# new-worktree.sh — create worktree + session, optionally start claude agent
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

ROOT=$(repo_root)
if [ -z "$ROOT" ]; then
    echo "Not a git repository"; read -n1 -r -p ""; exit 1
fi
REPO=$(repo_name)

echo "New worktree [$REPO]"
echo ""
read -r -p "Branch: " BRANCH
[ -z "$BRANCH" ] && exit 0

SESSION="${REPO}/${BRANCH}"
WT="$ROOT/$WORKTREE_DIR/$BRANCH"

if session_exists "$SESSION"; then
    # Write target for post-popup switch
    echo "$SESSION" > /tmp/knute-switch
    exit 0
fi

read -r -p "Task for claude (empty=shell only): " TASK

ensure_gitignore

# Create worktree
if [ ! -d "$WT" ]; then
    if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
        git worktree add "$WT" "$BRANCH"
    elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null; then
        git worktree add "$WT" "$BRANCH"
    else
        git worktree add -b "$BRANCH" "$WT"
    fi
    [ $? -ne 0 ] && { echo "Failed"; read -n1 -r -p ""; exit 1; }
fi

# Create session
if [ -n "$TASK" ]; then
    # Escape single quotes in task for safe shell embedding
    ESCAPED=$(printf '%s' "$TASK" | sed "s/'/'\\\\''/g")
    tmux new-session -d -s "$SESSION" -c "$WT" \
        "$CURRENT_DIR/claude-wrapper.sh '${ESCAPED}'"
    tmux rename-window -t "=$SESSION:0" "claude"
else
    tmux new-session -d -s "$SESSION" -c "$WT"
fi

# Write target for post-popup switch
echo "$SESSION" > /tmp/knute-switch
