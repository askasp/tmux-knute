#!/usr/bin/env bash
# knute.tmux — TPM entry point
# Single binding: prefix + K opens the unified dashboard.

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"

# Clean up old key table bindings from previous versions
tmux unbind-key -T knute Escape 2>/dev/null
tmux unbind-key -T knute w 2>/dev/null
tmux unbind-key -T knute a 2>/dev/null
tmux unbind-key -T knute x 2>/dev/null
tmux unbind-key -T knute m 2>/dev/null
tmux unbind-key -T knute l 2>/dev/null

# Also clean up old standalone prefix bindings
tmux unbind-key -T prefix A 2>/dev/null
tmux unbind-key -T prefix L 2>/dev/null
tmux unbind-key -T prefix M 2>/dev/null
tmux unbind-key -T prefix W 2>/dev/null
tmux unbind-key -T prefix X 2>/dev/null
tmux unbind-key -T prefix Z 2>/dev/null

tmux bind-key K display-popup -E -w 100% -h 100% -d '#{pane_current_path}' \
    "echo '#{session_name}' > /tmp/knute-session; '$SCRIPTS/dashboard.sh'; '$SCRIPTS/post-switch.sh'"
