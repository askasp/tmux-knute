#!/usr/bin/env bash
# issue-helpers.sh — shared utilities for GitHub issue operations

# Slugify a string for use as a branch name
# Usage: slugify "Add user authentication"  -> "add-user-authentication"
slugify() {
    echo "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9 -]//g' \
        | sed 's/  */ /g' \
        | sed 's/ /-/g' \
        | sed 's/--*/-/g' \
        | sed 's/^-//;s/-$//' \
        | cut -c1-50
}

# Parse dependency issue numbers from issue body
# Looks for: "depends on #N", "after #N", "blocked by #N" (case-insensitive)
# Returns space-separated list of issue numbers
parse_dependencies() {
    local body="$1"
    echo "$body" \
        | grep -ioE '(depends on|after|blocked by) #[0-9]+' \
        | grep -oE '#[0-9]+' \
        | tr -d '#' \
        | sort -un \
        | tr '\n' ' ' \
        | sed 's/ $//'
}

# Generate branch name for an issue
# Usage: issue_branch_name 42 "Add user authentication"  -> "issue-42-add-user-authentication"
issue_branch_name() {
    local number="$1" title="$2"
    local slug
    slug=$(slugify "$title")
    echo "issue-${number}-${slug}"
}

# Find existing branch matching an issue number
# Usage: find_issue_branch /repo/root 42  -> "issue-42-add-user-authentication" (or empty)
find_issue_branch() {
    local root="$1" number="$2"
    git -C "$root" branch --list "issue-${number}-*" 2>/dev/null | sed 's/^[* ]*//' | head -1
}

# Find the session name for an issue's worktree
# Usage: find_issue_session 42  -> "myrepo/issue-42-add-user-auth" (or empty)
find_issue_session() {
    local number="$1"
    tmux list-sessions -F '#S' 2>/dev/null | grep "/issue-${number}-" | head -1
}

# Write issue metadata to worktree
# Usage: write_issue_metadata /path/to/worktree 42 "Add auth" 41 "issue-41-setup-db"
write_issue_metadata() {
    local wt_path="$1" number="$2" title="$3" depends_on="$4" base_branch="$5"
    cat > "$wt_path/.knute-issue" <<EOF
number=$number
title=$title
depends_on=$depends_on
base_branch=$base_branch
EOF
}

# Read a single field from issue metadata
# Usage: read_issue_field /path/to/worktree "number"  -> "42"
read_issue_field() {
    local wt_path="$1" field="$2"
    grep "^${field}=" "$wt_path/.knute-issue" 2>/dev/null | cut -d= -f2-
}

# Check if gh CLI is available and authenticated
check_gh() {
    if ! command -v gh &>/dev/null; then
        echo "gh CLI required. Install: https://cli.github.com/"
        return 1
    fi
    if ! gh auth status &>/dev/null; then
        echo "Not authenticated. Run: gh auth login"
        return 1
    fi
    return 0
}
