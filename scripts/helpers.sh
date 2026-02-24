#!/usr/bin/env bash
# helpers.sh — shared utils for tmux-knute
# All scripts run inside display-popup with -d '#{pane_current_path}',
# so pwd is always the caller's directory.

WORKTREE_DIR=".worktrees"

repo_root() { git rev-parse --show-toplevel 2>/dev/null; }
repo_name() { basename "$(repo_root)"; }

# Get the caller's real tmux session name.
# Written to /tmp/knute-session by run-shell before the popup opens.
# Falls back to deriving from directory if the file doesn't exist.
current_session() {
    # Prefer the real session name stashed before popup opened
    if [ -f /tmp/knute-session ]; then
        cat /tmp/knute-session
        return
    fi
    # Fallback: derive from directory
    local cwd repo
    cwd=$(pwd)
    repo=$(repo_name)
    if [[ "$cwd" == */"$WORKTREE_DIR"/* ]]; then
        local branch
        branch=${cwd##*/"$WORKTREE_DIR"/}
        branch=${branch%%/*}
        echo "${repo}/${branch}"
    else
        echo "$repo"
    fi
}

ensure_gitignore() {
    local root gitignore
    root=$(repo_root) || return 1
    gitignore="$root/.gitignore"
    if [ ! -f "$gitignore" ] || ! grep -qxF "$WORKTREE_DIR" "$gitignore" 2>/dev/null; then
        echo "$WORKTREE_DIR" >> "$gitignore"
    fi
}

session_exists() { tmux has-session -t "=$1" 2>/dev/null; }

# Switch the real client (not the popup) to a target session
switch_to_session() {
    local target="$1"
    local caller
    caller=$(current_session)
    local client
    client=$(tmux list-clients -F '#{client_name} #{session_name}' 2>/dev/null \
        | grep " ${caller}$" | head -1 | awk '{print $1}')
    if [ -n "$client" ]; then
        tmux switch-client -c "$client" -t "=$target"
    else
        tmux switch-client -t "=$target"
    fi
}

# Parse --session NAME from arguments. Sets SESSION variable.
parse_session_arg() {
    SESSION=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) SESSION="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    [ -z "$SESSION" ] && SESSION=$(current_session)
}

# Resolve a repo/branch session name to the worktree path on disk
session_worktree_path() {
    local session="$1"
    local branch="${session#*/}"
    # Get main worktree root from the first pane of the session
    local pane_path
    pane_path=$(tmux list-panes -t "=$session" -F '#{pane_current_path}' 2>/dev/null | head -1)
    local main_root
    if [ -n "$pane_path" ]; then
        main_root=$(git -C "$pane_path" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
    fi
    # Fallback: try from current directory
    [ -z "$main_root" ] && main_root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
    [ -n "$main_root" ] && echo "$main_root/$WORKTREE_DIR/$branch"
}

# Inline @-file completion for task input
# Pressing @ during read -e triggers fzf file picker, inserts @path inline.
# Esc in picker inserts a literal @.
# Usage: setup_file_completion /path/to/workdir  (before read -e)
#        teardown_file_completion                 (after read -e)
setup_file_completion() {
    export _KNUTE_WORKDIR="$1"

    _knute_file_pick() {
        local selected
        selected=$(cd "$_KNUTE_WORKDIR" && {
            git ls-files 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null
        } | sort -u | fzf \
            --multi \
            --prompt="@ " \
            --header="tab:multi-select  enter:confirm  esc:cancel" \
            --pointer="▸" \
            --layout=reverse \
            --border=rounded \
            --preview="head -40 $_KNUTE_WORKDIR/{}" \
            --color="bg:#050506,fg:#8A8F98,hl:#5E6AD2,bg+:#111118,fg+:#EDEDEF,hl+:#6872D9,info:#5E6AD2,prompt:#5E6AD2,pointer:#5E6AD2,marker:#5E6AD2,spinner:#5E6AD2,header:#555566,border:#1a1a2e,gutter:#050506,preview-bg:#050506,preview-border:#1a1a2e,separator:#1a1a2e,query:#EDEDEF" \
            </dev/tty 2>/dev/tty)

        if [ -n "$selected" ]; then
            local insert=""
            while IFS= read -r f; do
                insert+="@${f} "
            done <<< "$selected"
            READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}${insert}${READLINE_LINE:$READLINE_POINT}"
            READLINE_POINT=$((READLINE_POINT + ${#insert}))
        else
            READLINE_LINE="${READLINE_LINE:0:$READLINE_POINT}@${READLINE_LINE:$READLINE_POINT}"
            READLINE_POINT=$((READLINE_POINT + 1))
        fi
    }

    bind -x '"@": _knute_file_pick'
}

teardown_file_completion() {
    bind -r '@' 2>/dev/null
    unset _KNUTE_WORKDIR
    unset -f _knute_file_pick 2>/dev/null
}

# Detect the main branch for a repo root
detect_main_branch() {
    local root="$1"
    # Check origin/HEAD first
    local ref
    ref=$(git -C "$root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
    if [ -n "$ref" ]; then
        echo "${ref##*/}"
        return
    fi
    # Fallback: check if main exists, else master
    if git -C "$root" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
        echo "main"
    else
        echo "master"
    fi
}

