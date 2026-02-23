#!/usr/bin/env bash
# new-agent.sh — add a claude agent window to a session
# Usage: new-agent.sh [--session NAME]
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

parse_session_arg "$@"

# Resolve working directory from target session
WORK_DIR=$(tmux list-panes -t "=$SESSION" -F '#{pane_current_path}' 2>/dev/null | head -1)
[ -z "$WORK_DIR" ] && WORK_DIR=$(pwd)

echo "New agent [$SESSION]"
echo ""
read -r -p "Window name: " NAME
[ -z "$NAME" ] && exit 0
read -r -p "Task: " TASK
[ -z "$TASK" ] && exit 0

ESCAPED=$(printf '%s' "$TASK" | sed "s/'/'\\\\''/g")
tmux new-window -t "=$SESSION" -n "$NAME" -c "$WORK_DIR" \
    "$CURRENT_DIR/claude-wrapper.sh '${ESCAPED}'"
