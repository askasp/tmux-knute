#!/usr/bin/env bash
# issues.sh — GitHub issue listing, preview, pipeline, and PR creation
#
# Modes:
#   --list REPO_ROOT              — print issues as fzf-formatted lines
#   --preview NUMBER REPO_ROOT    — show full issue body in preview pane
#   --start NUMBER REPO_ROOT      — create worktree + agent from issue
#   --create-pr SESSION           — create PR for a worktree session

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/issue-helpers.sh"

# Colors (same as dashboard.sh)
ACCENT=$'\033[38;2;94;106;210m'
GREEN=$'\033[38;2;74;222;128m'
AMBER=$'\033[38;2;229;164;69m'
RED=$'\033[38;2;229;83;75m'
FG=$'\033[38;2;237;237;239m'
MUTED=$'\033[38;2;138;143;152m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# --- Mode: --list REPO_ROOT ---
if [ "$1" = "--list" ]; then
    root="$2"
    [ -z "$root" ] && { echo "Usage: issues.sh --list REPO_ROOT"; exit 1; }

    check_gh || exit 0

    repo_name=$(basename "$root")

    # Cache with 60s TTL
    cache_file="/tmp/knute-issues-${repo_name}"
    if [ -f "$cache_file" ]; then
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [ "$cache_age" -lt 60 ]; then
            cat "$cache_file"
            exit 0
        fi
    fi

    # Fetch issues
    remote_url=$(git -C "$root" remote get-url origin 2>/dev/null)
    issues_json=$(gh issue list --state open --limit 50 \
        --json number,title,body,labels,assignees \
        -R "$remote_url" 2>/dev/null)

    if [ -z "$issues_json" ] || [ "$issues_json" = "[]" ]; then
        printf '%s\t%s\t%s\n' "---" "$root" "${MUTED}  No open issues${RESET}"
        exit 0
    fi

    output=""
    while IFS=$'\t' read -r number title body_oneline; do
        [ -z "$number" ] && continue

        # Check if a worktree/session already exists for this issue
        existing_session=$(find_issue_session "$number")
        existing_branch=$(find_issue_branch "$root" "$number")

        # Determine status indicator
        status=""
        if [ -n "$existing_session" ]; then
            # Check agent status in the session
            first_windex=$(tmux list-windows -t "=$existing_session" -F '#{window_index}' 2>/dev/null | head -1)
            if [ -n "$first_windex" ]; then
                agent_flag=$(tmux show-options -wqv -t "=$existing_session:$first_windex" @knute-agent 2>/dev/null)
                case "$agent_flag" in
                    running)
                        last_lines=$(tmux capture-pane -t "=$existing_session:$first_windex" -p -S -8 2>/dev/null)
                        if echo "$last_lines" | grep -qE '(Do you want|Allow |Deny |\[Y/n\]|\[y/N\]|Esc to cancel|❯ [0-9]+\.)'; then
                            status="${AMBER}● input${RESET}"
                        else
                            status="${ACCENT}● active${RESET}"
                        fi
                        ;;
                    done)
                        status="${GREEN}✓ done${RESET}"
                        ;;
                    *)
                        status="${GREEN}● started${RESET}"
                        ;;
                esac
            fi
        elif [ -n "$existing_branch" ]; then
            # Branch exists but no session — maybe merged or killed
            status="${MUTED}● branch exists${RESET}"
        else
            status="${MUTED}○ pending${RESET}"
        fi

        # Parse dependencies
        deps=$(parse_dependencies "$body_oneline")
        dep_text=""
        if [ -n "$deps" ]; then
            # Show first dependency
            first_dep=$(echo "$deps" | awk '{print $1}')
            dep_text="  ${MUTED}depends on #${first_dep}${RESET}"
        fi

        # Format: number (padded), title (truncated), dep info, status
        num_display=$(printf '%s#%-4s%s' "$ACCENT" "$number" "$RESET")
        title_truncated=$(echo "$title" | cut -c1-50)
        [ ${#title} -gt 50 ] && title_truncated="${title_truncated}…"

        line="${num_display}  ${FG}${title_truncated}${RESET}${dep_text}  ${status}"
        output+="${number}"$'\t'"${root}"$'\t'"${line}"$'\n'
    done < <(echo "$issues_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for issue in sorted(data, key=lambda x: x['number']):
    body = issue.get('body', '') or ''
    # Flatten body to single line for dependency parsing
    body_flat = body.replace('\n', ' ').replace('\t', ' ')
    print(f\"{issue['number']}\t{issue['title']}\t{body_flat}\")
" 2>/dev/null)

    if [ -n "$output" ]; then
        printf '%s' "$output" | tee "$cache_file"
    else
        printf '%s\t%s\t%s\n' "---" "$root" "${MUTED}  No open issues${RESET}"
    fi
    exit 0
fi

# --- Mode: --preview NUMBER REPO_ROOT ---
if [ "$1" = "--preview" ]; then
    number="$2" root="$3"
    [ "$number" = "---" ] && exit 0
    [ -z "$number" ] || [ -z "$root" ] && exit 0

    check_gh || exit 0

    # Fetch full issue details
    issue_json=$(gh issue view "$number" \
        --json number,title,body,labels,assignees,state \
        -R "$(git -C "$root" remote get-url origin 2>/dev/null)" 2>/dev/null)

    if [ -z "$issue_json" ]; then
        echo "${RED}Could not fetch issue #${number}${RESET}"
        exit 0
    fi

    title=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)
    body=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('body',''))" 2>/dev/null)
    labels=$(echo "$issue_json" | python3 -c "import json,sys; print(', '.join(l['name'] for l in json.load(sys.stdin).get('labels',[])))" 2>/dev/null)
    state=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state',''))" 2>/dev/null)

    echo "${ACCENT}#${number}${RESET}  ${FG}${BOLD}${title}${RESET}"
    [ -n "$labels" ] && echo "${MUTED}labels${RESET}   ${labels}"
    echo "${MUTED}state${RESET}    ${state}"
    echo ""

    # Show dependencies
    deps=$(parse_dependencies "$body")
    if [ -n "$deps" ]; then
        echo "${MUTED}depends on${RESET}  ${ACCENT}$(echo "$deps" | sed 's/\([0-9]*\)/#\1/g')${RESET}"
        echo ""
    fi

    # Show body
    if [ -n "$body" ]; then
        echo "${MUTED}─── description ───${RESET}"
        echo "$body"
        echo ""
    fi

    # Show branch status if worktree exists
    existing_branch=$(find_issue_branch "$root" "$number")
    if [ -n "$existing_branch" ]; then
        echo "${MUTED}─── branch ───${RESET}"
        echo "${MUTED}branch${RESET}   ${FG}${existing_branch}${RESET}"
        main_branch=$(detect_main_branch "$root")
        ahead=$(git -C "$root" rev-list --count "${main_branch}..${existing_branch}" 2>/dev/null)
        [ -n "$ahead" ] && echo "${MUTED}ahead${RESET}    ${ahead} commits"
    fi

    exit 0
fi

# --- Mode: --start NUMBER REPO_ROOT ---
if [ "$1" = "--start" ]; then
    number="$2" root="$3"
    [ -z "$number" ] || [ -z "$root" ] && { echo "Usage: issues.sh --start NUMBER REPO_ROOT"; read -n1 -r -p ""; exit 1; }

    check_gh || { read -n1 -r -p ""; exit 1; }

    repo=$(basename "$root")

    # Check if session already exists for this issue
    existing_session=$(find_issue_session "$number")
    if [ -n "$existing_session" ]; then
        echo "Session already exists: $existing_session"
        echo "$existing_session" > /tmp/knute-switch
        sleep 1
        exit 0
    fi

    # Fetch issue details
    echo "Fetching issue #${number}..."
    issue_json=$(gh issue view "$number" \
        --json number,title,body \
        -R "$(git -C "$root" remote get-url origin 2>/dev/null)" 2>/dev/null)

    if [ -z "$issue_json" ]; then
        echo "${RED}Could not fetch issue #${number}${RESET}"
        read -n1 -r -p ""
        exit 1
    fi

    title=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)
    body=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('body',''))" 2>/dev/null)

    # Determine branch name
    branch=$(issue_branch_name "$number" "$title")
    session="${repo}/${branch}"
    wt="$root/$WORKTREE_DIR/$branch"

    # Parse dependencies and determine base branch
    deps=$(parse_dependencies "$body")
    base_branch=$(detect_main_branch "$root")
    dep_number=""

    if [ -n "$deps" ]; then
        # Use the last (highest) dependency that has a branch
        for dep in $deps; do
            dep_branch=$(find_issue_branch "$root" "$dep")
            if [ -n "$dep_branch" ]; then
                base_branch="$dep_branch"
                dep_number="$dep"
            fi
        done
        if [ -z "$dep_number" ] && [ -n "$deps" ]; then
            first_dep=$(echo "$deps" | awk '{print $1}')
            echo "${AMBER}Warning: dependency #${first_dep} has no branch yet, branching from ${base_branch}${RESET}"
        fi
    fi

    echo "Issue:  #${number} ${title}"
    echo "Branch: ${branch}"
    echo "Base:   ${base_branch}"
    [ -n "$dep_number" ] && echo "Stack:  on top of #${dep_number}"
    echo ""

    ensure_gitignore "$root"

    # Create worktree
    if [ ! -d "$wt" ]; then
        existing_local=$(git -C "$root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null && echo yes)
        if [ "$existing_local" = "yes" ]; then
            git -C "$root" worktree add "$wt" "$branch"
        else
            git -C "$root" worktree add -b "$branch" "$wt" "$base_branch"
        fi
        if [ $? -ne 0 ]; then
            echo "${RED}Failed to create worktree${RESET}"
            read -n1 -r -p ""
            exit 1
        fi
    fi

    # Write issue metadata
    write_issue_metadata "$wt" "$number" "$title" "$dep_number" "$base_branch"

    # Construct Claude prompt from issue
    task="GitHub Issue #${number}: ${title}

${body}

Work on this issue. Create a PR-ready implementation. Make sure your commits reference issue #${number}."

    # Escape single quotes for shell embedding
    escaped_task=$(printf '%s' "$task" | sed "s/'/'\\\\''/g")

    # Create tmux session with Claude agent
    tmux new-session -d -s "$session" -c "$wt" \
        "$CURRENT_DIR/claude-wrapper.sh '${escaped_task}'"
    tmux rename-window -t "=$session:0" "claude"

    # Comment on the issue
    gh issue comment "$number" \
        --body "knute: started work in branch \`${branch}\`" \
        -R "$(git -C "$root" remote get-url origin 2>/dev/null)" 2>/dev/null &

    # Invalidate cache
    rm -f "/tmp/knute-issues-$(basename "$root")"

    # Write target for post-popup switch
    echo "$session" > /tmp/knute-switch
    exit 0
fi

# --- Mode: --create-pr SESSION ---
if [ "$1" = "--create-pr" ]; then
    session="$2"
    [ -z "$session" ] || [ "$session" = "---" ] && exit 0

    # Resolve worktree path
    wt_path=$(session_worktree_path "$session")
    if [ -z "$wt_path" ] || [ ! -d "$wt_path" ]; then
        echo "${RED}Could not resolve worktree for session: $session${RESET}"
        read -n1 -r -p ""
        exit 1
    fi

    check_gh || { read -n1 -r -p ""; exit 1; }

    # Read issue metadata
    issue_number=$(read_issue_field "$wt_path" "number")
    issue_title=$(read_issue_field "$wt_path" "title")
    dep_number=$(read_issue_field "$wt_path" "depends_on")
    stored_base=$(read_issue_field "$wt_path" "base_branch")

    branch="${session#*/}"
    repo_root=$(git -C "$wt_path" worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
    remote_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null)

    # Determine PR base branch
    if [ -n "$dep_number" ]; then
        dep_branch=$(find_issue_branch "$repo_root" "$dep_number")
        if [ -n "$dep_branch" ]; then
            base="$dep_branch"
        else
            base=$(detect_main_branch "$repo_root")
        fi
    elif [ -n "$stored_base" ]; then
        base="$stored_base"
    else
        base=$(detect_main_branch "$repo_root")
    fi

    echo "Creating PR for: ${branch}"
    echo "Base branch:     ${base}"
    [ -n "$issue_number" ] && echo "Closes:          #${issue_number}"
    echo ""

    # Push branch
    echo "Pushing branch..."
    git -C "$wt_path" push -u origin "$branch" 2>&1
    if [ $? -ne 0 ]; then
        echo "${RED}Failed to push branch${RESET}"
        read -n1 -r -p ""
        exit 1
    fi

    # Also push base branch if it's a stacked dependency branch
    if [ -n "$dep_number" ] && [ -n "$dep_branch" ]; then
        dep_wt="$repo_root/$WORKTREE_DIR/$dep_branch"
        if [ -d "$dep_wt" ]; then
            git -C "$dep_wt" push -u origin "$dep_branch" 2>&1
        fi
    fi

    # Build PR body
    pr_body=""
    [ -n "$issue_number" ] && pr_body+="Closes #${issue_number}"$'\n\n'
    if [ -n "$dep_number" ]; then
        pr_body+="Stacked on #${dep_number}"$'\n\n'
    fi

    # Construct PR title
    pr_title="${issue_title:-$branch}"
    [ -n "$issue_number" ] && pr_title="#${issue_number}: ${pr_title}"

    echo ""
    echo "Creating PR..."
    pr_url=$(gh pr create \
        --base "$base" \
        --head "$branch" \
        --title "$pr_title" \
        --body "$pr_body" \
        -R "$remote_url" 2>&1)

    if [ $? -eq 0 ]; then
        echo ""
        echo "${GREEN}PR created: ${pr_url}${RESET}"
    else
        echo ""
        echo "${RED}Failed to create PR${RESET}"
        echo "$pr_url"
    fi

    # Invalidate cache
    rm -f "/tmp/knute-issues-$(basename "$repo_root")"

    read -n1 -r -p "Press any key..."
    exit 0
fi

echo "Usage: issues.sh --list|--preview|--start|--create-pr [args...]"
exit 1
