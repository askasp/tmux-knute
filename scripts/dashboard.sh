#!/usr/bin/env bash
# dashboard.sh — unified fzf dashboard for tmux-knute
#
# Modes:
#   (default)                  — run the fzf dashboard
#   --list [REPO]              — print session list (for fzf reload)
#   --preview SESSION WINDEX   — print preview pane content
#   --lazygit SESSION          — open lazygit in session's workdir
#   --terminal SESSION         — open new shell window in session
#
# Keys inside fzf:
#   enter   → switch to session/window
#   ctrl-w  → new worktree + agent
#   ctrl-a  → new agent in selected session
#   ctrl-t  → new terminal in selected session
#   ctrl-x  → kill selected worktree
#   ctrl-g  → merge selected worktree
#   ctrl-l  → lazygit on selected session
#   ctrl-r  → refresh list

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Detect agent status for a window using @knute-agent option + pane content
# Returns: "running", "input", "done", or ""
agent_status() {
    local session="$1" windex="$2"
    local agent_flag
    agent_flag=$(tmux show-options -wqv -t "=$session:$windex" @knute-agent 2>/dev/null)

    if [ "$agent_flag" = "running" ]; then
        # Agent is running — check pane content for input prompts
        local last_lines
        last_lines=$(tmux capture-pane -t "=$session:$windex" -p -S -8 2>/dev/null)
        if echo "$last_lines" | grep -qE '(Do you want|Allow |Deny |\[Y/n\]|\[y/N\]|Esc to cancel|❯ [0-9]+\.)'; then
            echo "input"
        else
            echo "running"
        fi
    elif [ "$agent_flag" = "done" ]; then
        echo "done"
    fi
}

# --- Mode: --list [REPO] ---
# Format: SESSION<TAB>WINDEX<TAB>DISPLAY
# fzf uses --with-nth=3.. to show only the display column
if [ "$1" = "--list" ]; then
    filter_repo="$2"
    repo_file=$(mktemp) other_file=$(mktemp)
    trap "rm -f '$repo_file' '$other_file'" EXIT

    while IFS= read -r sname; do
        dest="$other_file"
        if [ -n "$filter_repo" ] && [[ "$sname" == "$filter_repo" || "$sname" == "$filter_repo"/* ]]; then
            dest="$repo_file"
        fi

        attached=$(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | grep "^${sname} " | awk '{print $2}')
        has_attention=false
        win_buf=""

        while IFS=$'\t' read -r windex wname wbell; do
            status_text=""
            astatus=$(agent_status "$sname" "$windex")

            case "$astatus" in
                input)
                    status_text="  ${RED}⏳ input${RESET}"
                    has_attention=true
                    ;;
                running)
                    status_text="  ${YELLOW}● active${RESET}"
                    ;;
                done)
                    if [ "$wbell" = "1" ]; then
                        status_text="  ${GREEN}✓ done ${RED}!${RESET}"
                        has_attention=true
                    else
                        status_text="  ${GREEN}✓ done${RESET}"
                    fi
                    ;;
                *)
                    # Not an agent — still show bell if set
                    [ "$wbell" = "1" ] && { status_text="  ${RED}!${RESET}"; has_attention=true; }
                    ;;
            esac

            win_buf+="${sname}"$'\t'"${windex}"$'\t'"  ${DIM}${windex}:${RESET} ${wname}${status_text}"$'\n'
        done < <(tmux list-windows -t "=$sname" -F '#{window_index}'$'\t''#{window_name}'$'\t''#{window_bell_flag}' 2>/dev/null)

        # Session header
        header="${BOLD}► ${sname}${RESET}"
        $has_attention && header+="  ${RED}!${RESET}"
        [ "$attached" = "1" ] && header+="  ${DIM}*${RESET}"

        printf '%s\t%s\t%s\n' "$sname" "-1" "$header" >> "$dest"
        printf '%s' "$win_buf" >> "$dest"
    done < <(tmux list-sessions -F '#S' 2>/dev/null)

    if [ -s "$repo_file" ] && [ -s "$other_file" ]; then
        cat "$repo_file"
        printf '%s\t%s\t%s\n' "---" "-1" "${DIM}  ─────────────────${RESET}"
        cat "$other_file"
    elif [ -s "$repo_file" ]; then
        cat "$repo_file"
    else
        cat "$other_file"
    fi
    exit 0
fi

# --- Mode: --preview SESSION WINDEX ---
if [ "$1" = "--preview" ]; then
    session="$2" windex="$3"
    [ "$session" = "---" ] && exit 0

    # Resolve working directory
    target="$session"
    [ "$windex" != "-1" ] && target="$session:$windex"
    wd=$(tmux list-panes -t "=$target" -F '#{pane_current_path}' 2>/dev/null | head -1)

    # Git info
    if [ -n "$wd" ] && git -C "$wd" rev-parse --git-dir &>/dev/null; then
        branch=$(git -C "$wd" branch --show-current 2>/dev/null)
        echo "${BOLD}Branch:${RESET} ${branch:-detached}"
        echo "${BOLD}Status:${RESET} $(git -C "$wd" status -sb 2>/dev/null | head -1)"
        echo ""
        echo "${DIM}Recent commits:${RESET}"
        git -C "$wd" log --oneline -5 2>/dev/null
    fi

    # Pane output for specific windows
    if [ "$windex" != "-1" ]; then
        echo ""
        echo "${DIM}── pane output ──${RESET}"
        tmux capture-pane -t "=$session:$windex" -p -S -20 2>/dev/null
    fi
    exit 0
fi

# --- Mode: --lazygit SESSION ---
if [ "$1" = "--lazygit" ]; then
    session="$2"
    [ -z "$session" ] || [ "$session" = "---" ] && exit 0
    if ! command -v lazygit &>/dev/null; then
        echo "lazygit is not installed"; read -n1 -r -p ""; exit 1
    fi
    wd=$(tmux list-panes -t "=$session" -F '#{pane_current_path}' 2>/dev/null | head -1)
    if [ -z "$wd" ]; then
        echo "Could not resolve path for $session"; read -n1 -r -p ""; exit 1
    fi
    cd "$wd" && exec lazygit
    exit 0
fi

# --- Mode: --terminal SESSION ---
if [ "$1" = "--terminal" ]; then
    session="$2"
    wd=$(tmux list-panes -t "=$session" -F '#{pane_current_path}' 2>/dev/null | head -1)
    tmux new-window -t "=$session" -c "${wd:-.}"
    exit 0
fi

# --- Default: run fzf dashboard ---
CURRENT=$(current_session)
REPO=$(repo_name 2>/dev/null)

SESSIONS=$("$CURRENT_DIR/dashboard.sh" --list "$REPO")
[ -z "$SESSIONS" ] && { echo "No sessions."; read -n1 -r -p ""; exit 0; }

SELECTED=$(echo "$SESSIONS" | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=3.. \
    --header="enter:switch  ^w:worktree  ^a:agent  ^t:terminal  ^x:kill  ^g:merge  ^l:lazygit  ^r:refresh" \
    --prompt="[$CURRENT] > " \
    --height=100% \
    --layout=reverse \
    --border=rounded \
    --preview "$CURRENT_DIR/dashboard.sh --preview '{1}' '{2}'" \
    --preview-window=right:40% \
    --bind "ctrl-r:reload($CURRENT_DIR/dashboard.sh --list $REPO)" \
    --bind "ctrl-w:execute($CURRENT_DIR/new-worktree.sh)+reload($CURRENT_DIR/dashboard.sh --list $REPO)" \
    --bind "ctrl-a:execute([ '{1}' != '---' ] && $CURRENT_DIR/new-agent.sh --session '{1}')+reload($CURRENT_DIR/dashboard.sh --list $REPO)" \
    --bind "ctrl-t:execute([ '{1}' != '---' ] && $CURRENT_DIR/dashboard.sh --terminal '{1}')+reload($CURRENT_DIR/dashboard.sh --list $REPO)" \
    --bind "ctrl-x:execute([ '{1}' != '---' ] && $CURRENT_DIR/kill-worktree.sh --session '{1}')+reload($CURRENT_DIR/dashboard.sh --list $REPO)" \
    --bind "ctrl-g:execute([ '{1}' != '---' ] && $CURRENT_DIR/merge-worktree.sh --session '{1}')+reload($CURRENT_DIR/dashboard.sh --list $REPO)" \
    --bind "ctrl-l:execute([ '{1}' != '---' ] && $CURRENT_DIR/dashboard.sh --lazygit '{1}')+reload($CURRENT_DIR/dashboard.sh --list $REPO)" \
)

# Handle enter: switch to selected session (and optionally window)
if [ -n "$SELECTED" ]; then
    session=$(printf '%s' "$SELECTED" | cut -d$'\t' -f1)
    windex=$(printf '%s' "$SELECTED" | cut -d$'\t' -f2 | tr -d ' ')

    if [ -n "$session" ] && [ "$session" != "---" ]; then
        echo "$session" > /tmp/knute-switch
        [ "$windex" != "-1" ] && echo "$windex" > /tmp/knute-window
    fi
fi
