#!/usr/bin/env bash
# test-secret-scan-skip.sh — Verify secret scanning skips when gitleaks not installed
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

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

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Stubs
log() { :; }
run_with_timeout() { shift; "$@"; }

# Source verify functions
source "$SRC_DIR/autopilot-verify.sh"

echo "=== Secret scan skip tests ==="

# Test 1: No PROJECT_SECRET_SCAN_CMD → skip
echo "Test 1: No gitleaks → graceful skip"
PROJECT_SECRET_SCAN_CMD=""
LAST_SECRET_SCAN_TIER=99
rc=0
verify_secrets "$TMPDIR_ROOT" || rc=$?
assert_eq "0" "$rc" "returns 0 when gitleaks not configured"
assert_eq "0" "$LAST_SECRET_SCAN_TIER" "tier stays 0 when skipped"

# Test 2: Unset PROJECT_SECRET_SCAN_CMD → skip
echo "Test 2: Unset var → graceful skip"
unset PROJECT_SECRET_SCAN_CMD 2>/dev/null || true
LAST_SECRET_SCAN_TIER=99
rc=0
verify_secrets "$TMPDIR_ROOT" || rc=$?
assert_eq "0" "$rc" "returns 0 when var unset"
assert_eq "0" "$LAST_SECRET_SCAN_TIER" "tier stays 0 when var unset"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
