#!/usr/bin/env bash
# post-switch.sh — switch to session/window from tmp files, then clean up
target=$(cat /tmp/knute-switch 2>/dev/null)
window=$(cat /tmp/knute-window 2>/dev/null)
rm -f /tmp/knute-switch /tmp/knute-window /tmp/knute-session

if [ -n "$target" ] && tmux has-session -t "=$target" 2>/dev/null; then
    tmux switch-client -t "=$target"
    [ -n "$window" ] && tmux select-window -t "=$target:$window"
fi

exit 0
