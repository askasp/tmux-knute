#!/usr/bin/env bash
# dashboard.sh — unified fzf dashboard for tmux-knute
#
# Modes:
#   (default)                  — run the fzf dashboard
#   --list [--collapsed] REPO  — print session list (for fzf reload)
#   --preview SESSION WINDEX   — print preview pane content
#   --lazygit SESSION          — open lazygit in session's workdir
#   --terminal SESSION         — open new shell window in session
#   --kill SESSION WINDEX      — kill a window or session/worktree
#
# Keys inside fzf:
#   enter   → switch to session/window
#   ctrl-w  → new worktree + agent
#   ctrl-a  → new agent in selected session
#   ctrl-t  → new terminal in selected session
#   ctrl-x  → kill selected window or session
#   ctrl-g  → merge selected worktree
#   ctrl-l  → lazygit on selected session
#   ctrl-e  → toggle expanded/collapsed view
#   ctrl-r  → refresh list

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

# Colors — Linear-inspired palette (truecolor)
ACCENT=$'\033[38;2;94;106;210m'      # #5E6AD2 indigo
GREEN=$'\033[38;2;74;222;128m'       # #4ADE80
AMBER=$'\033[38;2;229;164;69m'       # #E5A445
RED=$'\033[38;2;229;83;75m'          # #E5534B
FG=$'\033[38;2;237;237;239m'         # #EDEDEF
MUTED=$'\033[38;2;138;143;152m'      # #8A8F98
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Detect agent status for a window using @knute-agent option + pane content
agent_status() {
    local session="$1" windex="$2"
    local agent_flag
    agent_flag=$(tmux show-options -wqv -t "=$session:$windex" @knute-agent 2>/dev/null)

    if [ "$agent_flag" = "running" ]; then
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

# Count agents and attention items for a session (used in collapsed view)
session_summary() {
    local sname="$1"
    local nwin=0 nagent=0 has_bell=false
    while IFS=$'\t' read -r windex wname wbell; do
        nwin=$((nwin + 1))
        astatus=$(agent_status "$sname" "$windex")
        [ -n "$astatus" ] && nagent=$((nagent + 1))
        [ "$astatus" = "input" ] && has_bell=true
        [ "$wbell" = "1" ] && has_bell=true
    done < <(tmux list-windows -t "=$sname" -F '#{window_index}'$'\t''#{window_name}'$'\t''#{window_bell_flag}' 2>/dev/null)
    echo "${nwin}:${nagent}:${has_bell}"
}

# --- Mode: --list [REPO] ---
# Reads /tmp/knute-view for expanded/collapsed state
if [ "$1" = "--list" ]; then
    shift
    filter_repo="$1"
    collapsed=false
    [ "$(cat /tmp/knute-view 2>/dev/null)" = "collapsed" ] && collapsed=true
    repo_file=$(mktemp) other_file=$(mktemp)
    trap "rm -f '$repo_file' '$other_file'" EXIT

    while IFS= read -r sname; do
        dest="$other_file"
        if [ -n "$filter_repo" ] && [[ "$sname" == "$filter_repo" || "$sname" == "$filter_repo"/* ]]; then
            dest="$repo_file"
        fi

        attached=$(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null | grep "^${sname} " | awk '{print $2}')

        if $collapsed; then
            # Collapsed: one line per session with summary
            IFS=: read -r nwin nagent has_bell <<< "$(session_summary "$sname")"
            header="${ACCENT}▸${RESET} ${FG}${BOLD}${sname}${RESET}"
            header+="  ${MUTED}${nwin}w${RESET}"
            [ "$nagent" -gt 0 ] && header+="  ${MUTED}${nagent}a${RESET}"
            [ "$has_bell" = "true" ] && header+="  ${AMBER}●${RESET}"
            [ "$attached" = "1" ] && header+="  ${MUTED}*${RESET}"
            printf '%s\t%s\t%s\n' "$sname" "-1" "$header" >> "$dest"
        else
            # Expanded: session header + window rows
            has_attention=false
            win_buf=""

            while IFS=$'\t' read -r windex wname wbell; do
                status_text=""
                astatus=$(agent_status "$sname" "$windex")

                case "$astatus" in
                    input)
                        status_text="  ${AMBER}● input${RESET}"
                        has_attention=true
                        ;;
                    running)
                        status_text="  ${ACCENT}● active${RESET}"
                        ;;
                    done)
                        if [ "$wbell" = "1" ]; then
                            status_text="  ${GREEN}✓ done ${AMBER}●${RESET}"
                            has_attention=true
                        else
                            status_text="  ${GREEN}✓ done${RESET}"
                        fi
                        ;;
                    *)
                        [ "$wbell" = "1" ] && { status_text="  ${AMBER}●${RESET}"; has_attention=true; }
                        ;;
                esac

                win_buf+="${sname}"$'\t'"${windex}"$'\t'"    ${MUTED}${windex}${RESET}  ${wname}${status_text}"$'\n'
            done < <(tmux list-windows -t "=$sname" -F '#{window_index}'$'\t''#{window_name}'$'\t''#{window_bell_flag}' 2>/dev/null)

            header="${ACCENT}▸${RESET} ${FG}${BOLD}${sname}${RESET}"
            $has_attention && header+="  ${AMBER}●${RESET}"
            [ "$attached" = "1" ] && header+="  ${MUTED}*${RESET}"

            printf '%s\t%s\t%s\n' "$sname" "-1" "$header" >> "$dest"
            printf '%s' "$win_buf" >> "$dest"
        fi
    done < <(tmux list-sessions -F '#S' 2>/dev/null)

    if [ -s "$repo_file" ] && [ -s "$other_file" ]; then
        cat "$repo_file"
        printf '%s\t%s\t%s\n' "---" "-1" "${MUTED}  ───${RESET}"
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

    target="$session"
    [ "$windex" != "-1" ] && target="$session:$windex"
    wd=$(tmux list-panes -t "=$target" -F '#{pane_current_path}' 2>/dev/null | head -1)

    if [ -n "$wd" ] && git -C "$wd" rev-parse --git-dir &>/dev/null; then
        branch=$(git -C "$wd" branch --show-current 2>/dev/null)
        echo "${MUTED}branch${RESET}   ${FG}${branch:-detached}${RESET}"
        echo "${MUTED}status${RESET}   $(git -C "$wd" status -sb 2>/dev/null | head -1)"
        echo ""
        echo "${MUTED}commits${RESET}"
        git -C "$wd" log --oneline -5 2>/dev/null
    fi

    if [ "$windex" != "-1" ]; then
        echo ""
        echo "${MUTED}─── pane ───${RESET}"
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

# --- Mode: --new-session ---
if [ "$1" = "--new-session" ]; then
    # Create a plain tmux session in a user-picked directory
    read -r -p "Session name (blank=auto): " sname
    read -r -e -p "Directory [~]: " sdir
    sdir="${sdir:-$HOME}"
    sdir="${sdir/#\~/$HOME}"
    if [ -n "$sname" ]; then
        tmux new-session -d -s "$sname" -c "$sdir"
        echo "$sname" > /tmp/knute-switch
    else
        # Let tmux auto-name it
        sname=$(tmux new-session -d -P -F '#{session_name}' -c "$sdir")
        echo "$sname" > /tmp/knute-switch
    fi
    exit 0
fi

# --- Mode: --kill SESSION WINDEX ---
if [ "$1" = "--kill" ]; then
    session="$2" windex="$3"
    [ -z "$session" ] || [ "$session" = "---" ] && exit 0

    if [ "$windex" = "-1" ]; then
        # Kill entire session/worktree
        exec "$CURRENT_DIR/kill-worktree.sh" --session "$session"
    else
        # Kill specific window
        wname=$(tmux list-windows -t "=$session:$windex" -F '#{window_name}' 2>/dev/null)
        echo "Kill window $windex: $wname [$session]"
        echo ""
        read -r -p "Kill this window? [y/N] " confirm
        [[ "$confirm" =~ ^[yY]$ ]] && tmux kill-window -t "=$session:$windex" 2>/dev/null
    fi
    exit 0
fi

# --- Mode: --toggle ---
# Flips the view state file and exits (used by fzf execute-silent)
if [ "$1" = "--toggle" ]; then
    if [ "$(cat /tmp/knute-view 2>/dev/null)" = "expanded" ]; then
        echo "collapsed" > /tmp/knute-view
    else
        echo "expanded" > /tmp/knute-view
    fi
    exit 0
fi

# --- Default: run fzf dashboard ---
CURRENT=$(current_session)
REPO=$(repo_name 2>/dev/null)

# Default to collapsed
[ ! -f /tmp/knute-view ] && echo "collapsed" > /tmp/knute-view

RELOAD="$CURRENT_DIR/dashboard.sh --list $REPO"

SESSIONS=$("$CURRENT_DIR/dashboard.sh" --list "$REPO")
[ -z "$SESSIONS" ] && { echo "No sessions."; read -n1 -r -p ""; exit 0; }

SELECTED=$(echo "$SESSIONS" | fzf \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=3.. \
    --header="enter:switch  ^w:worktree  ^a:agent  ^t:term  ^n:new  ^x:kill  ^g:merge  ^l:lazygit  ^e:view" \
    --prompt="  $CURRENT ❯ " \
    --pointer="▸" \
    --height=100% \
    --layout=reverse \
    --border=rounded \
    --color="bg:#050506,fg:#8A8F98,hl:#5E6AD2,bg+:#111118,fg+:#EDEDEF,hl+:#6872D9,info:#5E6AD2,prompt:#5E6AD2,pointer:#5E6AD2,marker:#5E6AD2,spinner:#5E6AD2,header:#555566,border:#1a1a2e,gutter:#050506,preview-bg:#050506,preview-border:#1a1a2e,separator:#1a1a2e,query:#EDEDEF" \
    --preview "$CURRENT_DIR/dashboard.sh --preview '{1}' '{2}'" \
    --preview-window=right:40%:border-left \
    --bind "ctrl-r:reload($RELOAD)" \
    --bind "ctrl-e:execute-silent($CURRENT_DIR/dashboard.sh --toggle)+reload($RELOAD)" \
    --bind "ctrl-w:execute($CURRENT_DIR/new-worktree.sh)+reload($RELOAD)" \
    --bind "ctrl-a:execute([ '{1}' != '---' ] && $CURRENT_DIR/new-agent.sh --session '{1}')+reload($RELOAD)" \
    --bind "ctrl-t:execute-silent([ '{1}' != '---' ] && $CURRENT_DIR/dashboard.sh --terminal '{1}')+reload($RELOAD)" \
    --bind "ctrl-x:execute([ '{1}' != '---' ] && $CURRENT_DIR/dashboard.sh --kill '{1}' '{2}')+reload($RELOAD)" \
    --bind "ctrl-g:execute([ '{1}' != '---' ] && $CURRENT_DIR/merge-worktree.sh --session '{1}')+reload($RELOAD)" \
    --bind "ctrl-n:execute($CURRENT_DIR/dashboard.sh --new-session)+reload($RELOAD)" \
    --bind "ctrl-l:execute([ '{1}' != '---' ] && $CURRENT_DIR/dashboard.sh --lazygit '{1}')+reload($RELOAD)" \
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
