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

result=$(_count_cli_issues "$(printf 'Some preamble\n\nReview completed: 13 findings')")
assert_eq "13" "$result" "summary line: 13 findings"

result=$(_count_cli_issues "$(printf 'Review completed: 0 findings')")
assert_eq "0" "$result" "summary line: 0 findings"

result=$(_count_cli_issues "$(printf 'Review completed: 1 findings')")
assert_eq "1" "$result" "summary line: 1 finding"

# ─── Tests: _cr_cli_is_clean ──────────────────────────────────────────────

echo "Test: _cr_cli_is_clean"

rc=0; _cr_cli_is_clean "" || rc=$?
assert_eq "0" "$rc" "empty input = clean"

rc=0; _cr_cli_is_clean "all good" || rc=$?
assert_eq "0" "$rc" "short input = clean"

rc=0; _cr_cli_is_clean "No issues found in the reviewed code." || rc=$?
assert_eq "0" "$rc" "no issues text = clean"

rc=0; _cr_cli_is_clean "No findings detected." || rc=$?
assert_eq "0" "$rc" "no findings text = clean"

rc=0; _cr_cli_is_clean "$(printf 'Starting review...\n\nReview completed: 0 findings')" || rc=$?
assert_eq "0" "$rc" "Review completed: 0 findings = clean"

rc=0; _cr_cli_is_clean "$(printf 'Starting CodeRabbit review in plain text mode...\nConnecting to review service\nSetting up\nAnalyzing\nReviewing\n\nReview completed: 13 findings')" || rc=$?
assert_eq "1" "$rc" "Review completed: 13 findings = not clean"

rc=0; _cr_cli_is_clean "$(printf 'Starting CodeRabbit review in plain text mode...\nConnecting to review service\nSetting up\nAnalyzing\nReviewing\n\nReview completed: 1 findings')" || rc=$?
assert_eq "1" "$rc" "Review completed: 1 findings = not clean"

# Severity fallback (non-prompt-only formats)
rc=0; _cr_cli_is_clean "$(printf 'Long enough output to pass length check!!!\n**Severity**: CRITICAL\nSome issue found')" || rc=$?
assert_eq "1" "$rc" "severity CRITICAL = not clean"

rc=0; _cr_cli_is_clean "$(printf 'Long enough output to pass length check!!!\n**Severity**: HIGH\nSome issue found')" || rc=$?
assert_eq "1" "$rc" "severity HIGH = not clean"

rc=0; _cr_cli_is_clean "$(printf 'Long enough output to pass length check!!!\n[CRITICAL] buffer overflow detected')" || rc=$?
assert_eq "1" "$rc" "bracketed CRITICAL = not clean"

rc=0; _cr_cli_is_clean "$(printf 'Long enough output to pass length check!!!\n**Severity**: MEDIUM\nSome minor issue')" || rc=$?
assert_eq "0" "$rc" "severity MEDIUM only = clean (no CRITICAL/HIGH)"

# Format guard: long output with separators but no summary line
SEPARATOR="$(printf '=%.0s' {1..76})"
rc=0; _cr_cli_is_clean "$(printf 'Starting CodeRabbit review\nConnecting to service\nAnalyzing\n%s\nFile: foo.go\nLine: 10\nType: potential_issue\nSome long finding description that makes this output definitely over 200 chars long enough to trigger the guard and ensure we test correctly' "$SEPARATOR")" || rc=$?
assert_eq "1" "$rc" "format guard: separators without summary = not clean"

# No format guard for non-CR output
rc=0; _cr_cli_is_clean "$(printf 'This is just a long text output that has nothing to do with CodeRabbit and should not trigger the format guard because it lacks separator lines even though it is over 200 characters long enough to pass the length check')" || rc=$?
assert_eq "0" "$rc" "long non-CR output without separators = clean"

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

rc=0; _check_stall "5 3 3" 2 || rc=$?
assert_eq "0" "$rc" "stalled: last 2 identical"

rc=0; _check_stall "5 3 2" 2 || rc=$?
assert_eq "1" "$rc" "not stalled: counts differ"

rc=0; _check_stall "5" 2 || rc=$?
assert_eq "1" "$rc" "too few rounds"

rc=0; _check_stall "5 5 5" 3 || rc=$?
assert_eq "0" "$rc" "stalled: last 3 identical"

rc=0; _check_stall "0 0" 2 || rc=$?
assert_eq "1" "$rc" "not stalled: 0 means clean"

# ─── Tests: _classify_cr_error ─────────────────────────────────────────────

echo "Test: _classify_cr_error"

result=$(_classify_cr_error "")
assert_eq "unknown" "$result" "empty input"

result=$(_classify_cr_error "429 Too Many Requests")
assert_eq "rate_limit" "$result" "rate limit 429"

result=$(_classify_cr_error "Rate limit exceeded")
assert_eq "rate_limit" "$result" "rate limit text"

result=$(_classify_cr_error "$(printf 'Connecting to review service\nREVIEW ERROR: Review failed: Unknown error')")
assert_eq "service_error" "$result" "unknown error from service"

result=$(_classify_cr_error "Failed to start review: Review failed")
assert_eq "service_error" "$result" "failed to start review"

result=$(_classify_cr_error "TRPCClientError: connection refused")
assert_eq "service_error" "$result" "tRPC client error"

result=$(_classify_cr_error "Not logged in. Run coderabbit auth login")
assert_eq "auth_error" "$result" "not logged in"

result=$(_classify_cr_error "HTTP 401 Unauthorized")
assert_eq "auth_error" "$result" "401 unauthorized"

result=$(_classify_cr_error "some random error we haven't seen")
assert_eq "unknown" "$result" "unrecognized error"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
