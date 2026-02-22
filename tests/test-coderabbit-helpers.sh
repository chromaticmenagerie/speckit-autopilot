#!/usr/bin/env bash
# test-coderabbit-helpers.sh — Unit tests for CodeRabbit helper functions
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected '$expected', got '$actual'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

# Stub log
log() { :; }

# Source helpers
source "$SRC_DIR/autopilot-coderabbit-helpers.sh"

# ─── Tests: _count_cli_issues ───────────────────────────────────────────────

echo "Test: _count_cli_issues"

result=$(_count_cli_issues "")
assert_eq "0" "$result" "empty input"

result=$(_count_cli_issues "$(printf '1. Fix X\n2. Fix Y')")
assert_eq "2" "$result" "numbered list"

result=$(_count_cli_issues "$(printf -- '- Fix X\n- Fix Y\n- Fix Z')")
assert_eq "3" "$result" "bullet list"

result=$(_count_cli_issues "$(printf 'src/main.go:42 error\nsome prose')")
assert_eq "1" "$result" "file:line pattern"

result=$(_count_cli_issues "binary garbage")
assert_eq "0" "$result" "no actionable patterns"

# ─── Tests: _count_pr_issues ────────────────────────────────────────────────

echo "Test: _count_pr_issues"

result=$(_count_pr_issues "")
assert_eq "0" "$result" "empty input"

result=$(_count_pr_issues "$(printf 'comment1\n---\ncomment2\n---\ncomment3')")
assert_eq "3" "$result" "3 comments separated by ---"

result=$(_count_pr_issues "single comment no separator")
assert_eq "1" "$result" "single comment no separator"

# ─── Tests: _check_stall ────────────────────────────────────────────────────

echo "Test: _check_stall"

_check_stall "5 3 3" 2; rc=$?
assert_eq "0" "$rc" "stalled: last 2 identical"

_check_stall "5 3 2" 2; rc=$?
assert_eq "1" "$rc" "not stalled: counts differ"

_check_stall "5" 2; rc=$?
assert_eq "1" "$rc" "too few rounds"

_check_stall "5 5 5" 3; rc=$?
assert_eq "0" "$rc" "stalled: last 3 identical"

_check_stall "0 0" 2; rc=$?
assert_eq "1" "$rc" "not stalled: 0 means clean"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
