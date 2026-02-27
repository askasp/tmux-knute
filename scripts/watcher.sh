#!/usr/bin/env bash
# watcher.sh — background poller for GitHub issues and PR events
#
# Usage: watcher.sh REPO_ROOT [MAX_PARALLEL]
#
# Polls every 30s for:
# 1. New issues labeled "knute" → auto-creates worktree + agent
# 2. PR comments mentioning "knute" → spawns agent to fix feedback
# 3. Merged PRs → cleans up worktree + session
#
# Config: set KNUTE_MAX_PARALLEL env var or pass as 2nd arg (default: 3)
#
# Stores PID in /tmp/knute-watcher-{repo}.pid
# Logs to /tmp/knute-watcher-{repo}.log

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"
source "$CURRENT_DIR/issue-helpers.sh"

REPO_ROOT="$1"
[ -z "$REPO_ROOT" ] && { echo "Usage: watcher.sh REPO_ROOT [MAX_PARALLEL]"; exit 1; }

MAX_PARALLEL="${2:-${KNUTE_MAX_PARALLEL:-3}}"

REPO_NAME=$(basename "$REPO_ROOT")
PID_FILE="/tmp/knute-watcher-${REPO_NAME}.pid"
LOG_FILE="/tmp/knute-watcher-${REPO_NAME}.log"
REMOTE_URL=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)

# Write PID file
echo $$ > "$PID_FILE"

# Clean up on exit
cleanup() {
    rm -f "$PID_FILE"
    log "watcher stopped"
}
trap cleanup EXIT SIGTERM SIGINT

log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

log "watcher started for $REPO_NAME (pid $$, max_parallel=$MAX_PARALLEL)"

# Count currently active issue agents for this repo
count_active_agents() {
    local count=0
    while IFS= read -r sname; do
        [[ "$sname" != "$REPO_NAME"/issue-* ]] && continue
        local first_windex
        first_windex=$(tmux list-windows -t "=$sname" -F '#{window_index}' 2>/dev/null | head -1)
        local agent_flag
        agent_flag=$(tmux show-options -wqv -t "=$sname:$first_windex" @knute-agent 2>/dev/null)
        [ "$agent_flag" = "running" ] && count=$((count + 1))
    done < <(tmux list-sessions -F '#S' 2>/dev/null)
    echo "$count"
}

# Track what we've already processed to avoid duplicates
declare -A started_issues
declare -A handled_comments
declare -A cleaned_prs

# Initialize already-started issues from existing worktrees
while IFS= read -r branch; do
    num=$(echo "$branch" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+')
    [ -n "$num" ] && started_issues[$num]=1
done < <(git -C "$REPO_ROOT" branch --list "issue-*" 2>/dev/null | sed 's/^[* ]*//')

poll_issues() {
    # Fetch issues labeled "knute"
    local issues_json
    issues_json=$(gh issue list --label knute --state open --limit 20 \
        --json number,title,body \
        -R "$REMOTE_URL" 2>/dev/null)

    [ -z "$issues_json" ] || [ "$issues_json" = "[]" ] && return

    while IFS=$'\t' read -r number title body_flat; do
        [ -z "$number" ] && continue
        [ -n "${started_issues[$number]}" ] && continue

        # Parse dependencies
        local deps
        deps=$(parse_dependencies "$body_flat")

        # Check if dependencies are satisfied
        local deps_ok=true
        for dep in $deps; do
            local dep_session
            dep_session=$(find_issue_session "$dep")
            if [ -n "$dep_session" ]; then
                # Check if agent is done
                local first_windex
                first_windex=$(tmux list-windows -t "=$dep_session" -F '#{window_index}' 2>/dev/null | head -1)
                local agent_flag
                agent_flag=$(tmux show-options -wqv -t "=$dep_session:$first_windex" @knute-agent 2>/dev/null)
                if [ "$agent_flag" != "done" ]; then
                    deps_ok=false
                    break
                fi
            else
                # Dependency not started yet — check if it has a branch with commits
                local dep_branch
                dep_branch=$(find_issue_branch "$REPO_ROOT" "$dep")
                if [ -z "$dep_branch" ]; then
                    deps_ok=false
                    break
                fi
            fi
        done

        if $deps_ok; then
            # Enforce parallel limit
            local active
            active=$(count_active_agents)
            if [ "$active" -ge "$MAX_PARALLEL" ]; then
                log "parallel limit reached ($active/$MAX_PARALLEL), skipping #${number} for now"
                continue
            fi

            log "starting issue #${number}: ${title} ($((active+1))/$MAX_PARALLEL)"
            started_issues[$number]=1
            "$CURRENT_DIR/issues.sh" --start "$number" "$REPO_ROOT" </dev/null &>/dev/null &
        fi
    done < <(echo "$issues_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for issue in sorted(data, key=lambda x: x['number']):
    body = (issue.get('body') or '').replace('\n', ' ').replace('\t', ' ')
    print(f\"{issue['number']}\t{issue['title']}\t{body}\")
" 2>/dev/null)
}

poll_pr_comments() {
    # Check open PRs created by knute for new review comments mentioning "knute"
    local prs_json
    prs_json=$(gh pr list --state open --limit 20 \
        --json number,headRefName \
        -R "$REMOTE_URL" 2>/dev/null)

    [ -z "$prs_json" ] || [ "$prs_json" = "[]" ] && return

    while IFS=$'\t' read -r pr_number branch; do
        [ -z "$pr_number" ] && continue

        # Only process PRs that have a knute worktree
        local session="${REPO_NAME}/${branch}"
        if ! tmux has-session -t "=$session" 2>/dev/null; then
            continue
        fi

        # Check for review comments mentioning "knute"
        local comments
        comments=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/comments" \
            -R "$REMOTE_URL" \
            --jq '.[] | select(.body | test("knute"; "i")) | "\(.id)\t\(.path)\t\(.body)"' 2>/dev/null)

        # Also check issue comments on the PR
        local issue_comments
        issue_comments=$(gh api "repos/{owner}/{repo}/issues/${pr_number}/comments" \
            -R "$REMOTE_URL" \
            --jq '.[] | select(.body | test("knute"; "i")) | "\(.id)\t\t\(.body)"' 2>/dev/null)

        local all_comments="${comments}${issue_comments:+$'\n'$issue_comments}"
        [ -z "$all_comments" ] && continue

        while IFS=$'\t' read -r comment_id file_path comment_body; do
            [ -z "$comment_id" ] && continue
            [ -n "${handled_comments[$comment_id]}" ] && continue
            handled_comments[$comment_id]=1

            log "PR #${pr_number}: handling comment $comment_id on ${file_path:-general}"

            # Build task for the agent
            local task="Fix PR review feedback on PR #${pr_number}:"$'\n\n'
            if [ -n "$file_path" ]; then
                task+="File: ${file_path}"$'\n'
            fi
            task+="Comment: ${comment_body}"$'\n\n'
            task+="Address this review feedback and commit the fix."

            # Get worktree path
            local wt_path
            wt_path=$(session_worktree_path "$session")

            if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
                # Spawn a new agent window in the session
                local escaped_task
                escaped_task=$(printf '%s' "$task" | sed "s/'/'\\\\''/g")
                tmux new-window -t "=$session" -c "$wt_path" \
                    "$CURRENT_DIR/claude-wrapper.sh '${escaped_task}'"

                log "spawned fix agent for PR #${pr_number} comment $comment_id"
            fi
        done <<< "$all_comments"
    done < <(echo "$prs_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pr in data:
    print(f\"{pr['number']}\t{pr['headRefName']}\")
" 2>/dev/null)
}

poll_merged_prs() {
    # Check for recently merged PRs that have knute worktrees
    local prs_json
    prs_json=$(gh pr list --state merged --limit 10 \
        --json number,headRefName,mergedAt \
        -R "$REMOTE_URL" 2>/dev/null)

    [ -z "$prs_json" ] || [ "$prs_json" = "[]" ] && return

    while IFS=$'\t' read -r pr_number branch; do
        [ -z "$pr_number" ] && continue
        [ -n "${cleaned_prs[$pr_number]}" ] && continue

        local session="${REPO_NAME}/${branch}"

        # Only clean up if we have a session/worktree for this
        if tmux has-session -t "=$session" 2>/dev/null; then
            log "PR #${pr_number} merged, cleaning up session ${session}"
            cleaned_prs[$pr_number]=1

            # Kill the session and remove worktree
            "$CURRENT_DIR/kill-worktree.sh" --session "$session" --force </dev/null &>/dev/null

            # Invalidate cache
            rm -f "/tmp/knute-issues-${REPO_NAME}"
        elif [ -d "$REPO_ROOT/$WORKTREE_DIR/$branch" ]; then
            log "PR #${pr_number} merged, cleaning up worktree $branch"
            cleaned_prs[$pr_number]=1

            git -C "$REPO_ROOT" worktree remove --force "$REPO_ROOT/$WORKTREE_DIR/$branch" 2>/dev/null
            git -C "$REPO_ROOT" branch -d "$branch" 2>/dev/null
        fi
    done < <(echo "$prs_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for pr in data:
    print(f\"{pr['number']}\t{pr['headRefName']}\")
" 2>/dev/null)
}

poll_done_agents() {
    # Check if any agents have finished and need PRs created
    while IFS= read -r sname; do
        # Only process issue-based sessions
        [[ "$sname" != *"/issue-"* ]] && continue

        local wt_path
        wt_path=$(session_worktree_path "$sname")
        [ -z "$wt_path" ] || [ ! -f "$wt_path/.knute-issue" ] && continue

        # Check if PR already exists for this branch
        local branch="${sname#*/}"
        local existing_pr
        existing_pr=$(gh pr list --head "$branch" --state open --limit 1 \
            --json number -R "$REMOTE_URL" 2>/dev/null)
        [ -n "$existing_pr" ] && [ "$existing_pr" != "[]" ] && continue

        # Check if the first window's agent is done
        local first_windex
        first_windex=$(tmux list-windows -t "=$sname" -F '#{window_index}' 2>/dev/null | head -1)
        local agent_flag
        agent_flag=$(tmux show-options -wqv -t "=$sname:$first_windex" @knute-agent 2>/dev/null)

        if [ "$agent_flag" = "done" ]; then
            # Check if there are actual commits to push
            local main_branch
            main_branch=$(detect_main_branch "$REPO_ROOT")
            local ahead
            ahead=$(git -C "$wt_path" rev-list --count "${main_branch}..HEAD" 2>/dev/null)

            if [ -n "$ahead" ] && [ "$ahead" -gt 0 ]; then
                log "agent done for ${sname}, creating PR"
                "$CURRENT_DIR/issues.sh" --create-pr "$sname" </dev/null &>/dev/null
            fi
        fi
    done < <(tmux list-sessions -F '#S' 2>/dev/null)
}

# Main poll loop
while true; do
    poll_issues
    poll_pr_comments
    poll_merged_prs
    poll_done_agents
    sleep 30
done
