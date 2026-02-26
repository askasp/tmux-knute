#!/usr/bin/env bash
# new-worktree.sh — create worktree + session, optionally start claude agent
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

# Parse --session from dashboard (the hovered session)
HOVER_SESSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --session) HOVER_SESSION="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Resolve repo root from hovered session, fall back to caller session
SOURCE_DIR=""
if [ -n "$HOVER_SESSION" ] && [ "$HOVER_SESSION" != "---" ]; then
    SOURCE_DIR=$(tmux list-panes -t "=$HOVER_SESSION" -F '#{pane_current_path}' 2>/dev/null | head -1)
fi
if [ -z "$SOURCE_DIR" ]; then
    CALLER_SESSION=$(cat /tmp/knute-session 2>/dev/null)
    [ -n "$CALLER_SESSION" ] && SOURCE_DIR=$(tmux list-panes -t "=$CALLER_SESSION" -F '#{pane_current_path}' 2>/dev/null | head -1)
fi
[ -z "$SOURCE_DIR" ] && SOURCE_DIR=$(pwd)

# Get the main worktree root (not a child worktree)
DEFAULT_ROOT=$(git -C "$SOURCE_DIR" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
[ -z "$DEFAULT_ROOT" ] && DEFAULT_ROOT="$SOURCE_DIR"

echo "Repo: $DEFAULT_ROOT"
echo "(enter to confirm, or type a different path)"
read -e -p "> " CUSTOM_ROOT
ROOT="${CUSTOM_ROOT:-$DEFAULT_ROOT}"
ROOT="${ROOT/#\~/$HOME}"

if ! git -C "$ROOT" rev-parse --git-dir &>/dev/null; then
    echo "Not a git repository: $ROOT"; read -n1 -r -p ""; exit 1
fi
ROOT=$(git -C "$ROOT" rev-parse --show-toplevel)
REPO=$(basename "$ROOT")

echo ""
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

setup_file_completion "$ROOT"
read -e -p "Task for claude (@=files, empty=shell only): " TASK
teardown_file_completion

ensure_gitignore "$ROOT"

# Create worktree (all git commands target $ROOT explicitly)
if [ ! -d "$WT" ]; then
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
        git -C "$ROOT" worktree add "$WT" "$BRANCH"
    elif git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/$BRANCH" 2>/dev/null; then
        git -C "$ROOT" worktree add "$WT" "$BRANCH"
    else
        git -C "$ROOT" worktree add -b "$BRANCH" "$WT"
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
