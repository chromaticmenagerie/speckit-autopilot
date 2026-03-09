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
    (cd "$repo_root" && gh api "repos/{owner}/{repo}/pulls/$pr_num/reviews" \
        --jq '[.[] | select(.user.login=="coderabbitai[bot]")] | last | .state // empty' \
        2>/dev/null) || echo ""
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
# Severity filtering: only CRITICAL and HIGH findings count as "not clean."
# LOW, INFO, and MEDIUM findings are ignored to avoid infinite convergence
# loops — prompt_coderabbit_fix tells Claude to skip LOW and only optionally
# fix MEDIUM, so the clean check must align with that policy.
_cr_cli_is_clean() {
    local output="$1"
    [[ -z "$output" ]] && return 0
    # Heuristic: if output explicitly says no issues found
    echo "$output" | grep -qi "no issues\|no problems\|looks good\|no suggestions\|no findings" && return 0
    # If very short (< 50 chars), likely a "nothing to report" message
    [[ ${#output} -lt 50 ]] && return 0
    # Severity filter: only fail on CRITICAL or HIGH findings.
    # Matches patterns like "**Severity**: CRITICAL", "severity: high",
    # "Severity: CRITICAL", "[CRITICAL]", "[HIGH]", etc.
    if echo "$output" | grep -qiE '\*{0,2}severity\*{0,2}\s*:?\s*(critical|high)|\[(critical|high)\]'; then
        return 1
    fi
    # No CRITICAL/HIGH findings — treat as clean even if LOW/MEDIUM/INFO remain
    return 0
}

# ─── Error Classification ──────────────────────────────────────────────────

# Classify CodeRabbit CLI error output into categories.
# Returns: "rate_limit", "service_error", "auth_error", or "unknown"
_classify_cr_error() {
    local output="$1"
    [[ -z "$output" ]] && echo "unknown" && return

    # Rate limit
    if echo "$output" | grep -qi "rate.limit\|429\|too many requests"; then
        echo "rate_limit"; return
    fi

    # Service/connectivity errors (transient — worth retrying with backoff)
    if echo "$output" | grep -qi "unknown error\|failed to start review\|connecting to review service\|ECONNREFUSED\|ETIMEDOUT\|socket hang up\|TRPCClientError\|websocket\|network error"; then
        echo "service_error"; return
    fi

    # Auth errors (not transient — skip immediately)
    if echo "$output" | grep -qi "not logged in\|not authenticated\|unauthorized\|401\|auth.*fail\|login required"; then
        echo "auth_error"; return
    fi

    echo "unknown"
}

# ─── Issue Counting ─────────────────────────────────────────────────────────

# Count actionable issues in CLI review output.
# Primary: unique file:line references (works with --prompt-only prose output).
# Fallback: numbered/bullet lists and line-start file:line patterns.
# Uses whichever method finds more issues to avoid undercounting.
_count_cli_issues() {
    local output="$1"
    [[ -z "$output" ]] && echo "0" && return
    local count=0
    # Primary: count unique file:line references (inline in prose)
    local file_refs
    file_refs=$(echo "$output" | grep -oE '[a-zA-Z0-9_/.+-]+\.(go|ts|tsx|js|jsx|svelte|py|sh|sql|yaml|yml|md|css|html):[0-9]+' | sort -u | wc -l)
    # Fallback: original list-pattern matching
    local list_count
    list_count=$(echo "$output" | grep -cE '^\s*[0-9]+\.|^\s*[-*]\s|^[^[:space:]]+:[0-9]+' || true)
    # Use whichever finds more issues
    if [[ "$file_refs" -gt "$list_count" ]]; then
        count=$file_refs
    else
        count=$list_count
    fi
    count="${count:-0}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
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
