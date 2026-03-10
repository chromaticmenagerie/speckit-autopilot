#!/usr/bin/env bash
# autopilot-review-helpers.sh — Review helper functions (tier-aware dispatch)
#
# Sourced by autopilot-review.sh

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ─── CLI Review Helpers ──────────────────────────────────────────────────────

# Check if CodeRabbit CLI output indicates clean review.
# Primary: parse "Review completed: N findings" summary line from --prompt-only output.
# Fallback: severity regex for non-prompt-only formats.
# Format guard: long output with finding separators but no recognized summary = not clean.
_cr_cli_is_clean() {
    local output="$1"
    [[ -z "$output" ]] && return 0
    # Heuristic: if output explicitly says no issues found
    echo "$output" | grep -qi "no issues\|no problems\|looks good\|no suggestions\|no findings" && return 0
    # If very short (< 50 chars), likely a "nothing to report" message
    [[ ${#output} -lt 50 ]] && return 0

    # Primary: parse --prompt-only summary line "Review completed: N findings"
    local finding_count
    finding_count=$(echo "$output" | grep -oE 'Review completed: [0-9]+ findings' | grep -oE '[0-9]+' || echo "")
    if [[ -n "$finding_count" ]]; then
        (( finding_count > 0 )) && return 1
        return 0
    fi

    # Fallback: severity regex for non-prompt-only formats
    if echo "$output" | grep -qiE '\*{0,2}severity\*{0,2}\s*:?\s*(critical|high)|\[(critical|high)\]'; then
        return 1
    fi

    # Format guard: long output with finding separators but no recognized summary
    # Fail-closed to prevent silent skip of unrecognized review output
    if [[ ${#output} -gt 200 ]] && echo "$output" | grep -qE '^={10,}$'; then
        log WARN "CodeRabbit output has finding separators but no recognized summary — treating as not clean"
        return 1
    fi

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

# Count actionable issues in CLI review output.
# Primary: parse "Review completed: N findings" summary line (accurate for --prompt-only).
# Fallback: unique file:line references and list-pattern matching.
_count_cli_issues() {
    local output="$1"
    [[ -z "$output" ]] && echo "0" && return

    # Primary: parse --prompt-only summary line
    local summary_count
    summary_count=$(echo "$output" | grep -oE 'Review completed: [0-9]+ findings' | grep -oE '[0-9]+' || echo "")
    if [[ -n "$summary_count" ]]; then
        echo "$summary_count"
        return
    fi

    # Fallback: heuristic counting for non-prompt-only formats
    local count=0
    local file_refs
    file_refs=$(echo "$output" | grep -oE '[a-zA-Z0-9_/.+-]+\.(go|ts|tsx|js|jsx|svelte|py|sh|sql|yaml|yml|md|css|html):[0-9]+' | sort -u | wc -l)
    local list_count
    list_count=$(echo "$output" | grep -cE '^\s*[0-9]+\.|^\s*[-*]\s|^[^[:space:]]+:[0-9]+' || true)
    if [[ "$file_refs" -gt "$list_count" ]]; then
        count=$file_refs
    else
        count=$list_count
    fi
    count="${count:-0}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
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

# ─── Tier-Aware Dispatch ──────────────────────────────────────────────────────

# Tier-aware cleanness check
_review_is_clean() {
    local tier="$1" output="$2"
    case "$tier" in
        cli)    _cr_cli_is_clean "$output" ;;
        codex)  _codex_is_clean "$output" ;;
        self)   _self_review_is_clean "$output" ;;
        *)      return 1 ;;
    esac
}

# Tier-aware issue counting
_count_review_issues() {
    local tier="$1" output="$2"
    case "$tier" in
        cli)    _count_cli_issues "$output" ;;
        codex)  _count_codex_issues "$output" ;;
        self)   _count_self_issues "$output" ;;
        *)      echo 0 ;;
    esac
}

# Tier-aware error classification
_classify_review_error() {
    local tier="$1" output="$2"
    case "$tier" in
        cli)    _classify_cr_error "$output" ;;
        codex)  _classify_codex_error "$output" ;;
        self)   echo "claude_error" ;;
        *)      echo "unknown" ;;
    esac
}

# ─── Codex Helpers ───────────────────────────────────────────────────────────
# Codex output parsing — jq-first, grep-fallback (Decision #21)
# agent_message.text may be JSON ({"findings":[...]}) or plain text with [P0]-[P3] markers.
#
# IMPORTANT: Parentheses in (.findings // []) are ESSENTIAL.
# Without them: .findings // [] | length == 0
#   parses as: .findings // ([] | length == 0) → .findings // true — WRONG.
# With them: (.findings // []) | length == 0
#   parses as: (fallback to []) | length == 0 — CORRECT.

_codex_is_clean() {
    local output="$1"
    [[ -z "$output" ]] && return 1  # empty = error, not clean

    # Primary: structured output via --output-schema (overall_correctness field)
    local correctness
    correctness=$(echo "$output" | jq -r '.overall_correctness // empty' 2>/dev/null) || true
    if [[ "$correctness" == "true" ]]; then
        # Cross-check: no P0/P1 findings despite overall_correctness=true
        local high_count
        high_count=$(echo "$output" | jq '[(.findings // [])[] | select((.priority // 99) <= 1)] | length' 2>/dev/null) || high_count=0
        [[ "$high_count" -eq 0 ]] && return 0
        return 1  # contradictory — conservative
    elif [[ "$correctness" == "false" ]]; then
        return 1
    fi

    # Fallback: JSON path (findings array, no overall_correctness)
    local jq_rc=0
    echo "$output" | jq -e '(.findings // []) | length == 0' >/dev/null 2>&1 || jq_rc=$?
    case $jq_rc in
        0) return 0 ;;  # JSON parsed, findings empty → clean
        1) return 1 ;;  # JSON parsed, findings non-empty → issues
        # 4|5 = not valid JSON → fall through to text parsing
    esac

    # Text path: P0-P2 severity markers (grep-fallback for when schema silently dropped)
    if echo "$output" | grep -qE '\[P[0-2]\]'; then
        return 1
    fi

    # Clean language indicators
    if echo "$output" | grep -qi "no issues\|no findings\|no problems\|appears correct\|no defects\|patch is correct"; then
        return 0
    fi

    return 1  # conservative default
}

_count_codex_issues() {
    local output="$1"
    [[ -z "$output" ]] && echo "0" && return

    # JSON path: count findings with priority <= 2 (P0-P2)
    # (.priority // 99) prevents null <= 2 evaluating to true in jq
    local jq_count
    jq_count=$(echo "$output" | jq '[(.findings // [])[] | select((.priority // 99) <= 2)] | length' 2>/dev/null) || jq_count=""
    if [[ -n "$jq_count" ]] && [[ "$jq_count" =~ ^[0-9]+$ ]]; then
        echo "$jq_count"
        return
    fi

    # Text path: count P0-P2 marker lines
    local count
    count=$(echo "$output" | grep -coE '\[P[0-2]\]' 2>/dev/null) || count=0
    echo "$count"
}

_classify_codex_error() {
    local output="$1"
    if echo "$output" | grep -qi "rate.limit\|429"; then echo "rate_limit"; return; fi
    if echo "$output" | grep -qi "auth\|unauthorized\|401\|403"; then echo "auth_error"; return; fi
    if echo "$output" | grep -qi "timeout\|timed.out"; then echo "timeout"; return; fi
    echo "service_error"
}

# ─── Claude Self-Review Helpers ───────────────────────────────────────────────

_self_review_is_clean() {
    local output="$1"
    [[ -z "$output" ]] && return 1
    if echo "$output" | grep -qi "no issues\|no findings\|all clear\|LGTM\|no problems found"; then
        return 0
    fi
    # Check if only LOW severity findings
    local high_count
    high_count=$(echo "$output" | grep -ciE '(CRITICAL|HIGH):' 2>/dev/null) || high_count=0
    [[ "$high_count" -eq 0 ]] && return 0
    return 1
}

_count_self_issues() {
    local output="$1"
    local count
    count=$(echo "$output" | grep -ciE '(CRITICAL|HIGH|MEDIUM):' 2>/dev/null) || count=0
    echo "$count"
}
