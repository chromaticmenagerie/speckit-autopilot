#!/usr/bin/env bash
# autopilot-coderabbit-helpers.sh — CodeRabbit helper functions
#
# Extracted from autopilot-coderabbit.sh: PR review state queries,
# comment fetching, CLI output classification, issue counting.
#
# Sourced by autopilot-coderabbit.sh.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ─── PR Review Helpers ───────────────────────────────────────────────────────

# Get latest coderabbitai[bot] review state from GitHub API.
# Returns: APPROVED, CHANGES_REQUESTED, or empty.
_cr_pr_review_state() {
    local repo_root="$1" pr_num="$2"
    cd "$repo_root" && gh api "repos/{owner}/{repo}/pulls/$pr_num/reviews" \
        --jq '[.[] | select(.user.login=="coderabbitai[bot]")] | last | .state // empty' \
        2>/dev/null || echo ""
}

# Get coderabbitai[bot] review comments as text for Claude.
_cr_pr_comments() {
    local repo_root="$1" pr_num="$2"
    local body inline

    # Summary review body
    body=$(cd "$repo_root" && gh api "repos/{owner}/{repo}/pulls/$pr_num/reviews" \
        --jq '[.[] | select(.user.login=="coderabbitai[bot]")] | last | .body // ""' \
        2>/dev/null || echo "")

    # Inline file comments
    inline=$(cd "$repo_root" && gh api "repos/{owner}/{repo}/pulls/$pr_num/comments" \
        --jq '[.[] | select(.user.login=="coderabbitai[bot]")] | map(.path + ":" + (.line|tostring) + " " + .body) | join("\n---\n")' \
        2>/dev/null || echo "")

    echo "${body}"
    if [[ -n "$inline" ]]; then
        echo ""
        echo "INLINE COMMENTS:"
        echo "$inline"
    fi
}

# Check if CodeRabbit CLI output indicates clean review.
_cr_cli_is_clean() {
    local output="$1"
    [[ -z "$output" ]] && return 0
    # Heuristic: if output contains no actionable findings
    echo "$output" | grep -qi "no issues\|no problems\|looks good\|no suggestions\|no findings" && return 0
    # If very short (< 50 chars), likely a "nothing to report" message
    [[ ${#output} -lt 50 ]] && return 0
    return 1
}

# ─── Issue Counting ─────────────────────────────────────────────────────────

# Count actionable issues in CLI review output.
# Matches: numbered lists (1.), bullet lists (- or *), file:line patterns.
# Conservative: undercounts preferred over overcounts.
_count_cli_issues() {
    local output="$1"
    [[ -z "$output" ]] && echo "0" && return
    local count
    count=$(echo "$output" | grep -cE '^\s*[0-9]+\.|^\s*[-*]\s|^[^[:space:]]+:[0-9]+' || true)
    echo "${count:-0}"
}

# Count issues in PR review comments (separated by ---).
_count_pr_issues() {
    local output="$1"
    [[ -z "$output" ]] && echo "0" && return
    local separators
    separators=$(echo "$output" | grep -cE '^---$' || true)
    echo $((separators + 1))
}

# ─── Stall Detection ────────────────────────────────────────────────────────

# Check if issue counts have stalled (last N rounds identical, non-zero).
# Args: space-separated counts string, stall_rounds threshold.
# Returns: 0 if stalled, 1 if not.
_check_stall() {
    local counts_str="$1" stall_rounds="$2"
    local -a counts
    read -ra counts <<< "$counts_str"
    local n=${#counts[@]}

    # Too few rounds to judge
    (( n < stall_rounds )) && return 1

    # Guard: last count is 0 means clean — not stalled
    local last="${counts[$((n - 1))]}"
    (( last == 0 )) && return 1

    # Check if last N entries are identical
    local i
    for (( i = n - stall_rounds + 1; i < n; i++ )); do
        [[ "${counts[$i]}" != "${counts[$((i - 1))]}" ]] && return 1
    done
    return 0
}
