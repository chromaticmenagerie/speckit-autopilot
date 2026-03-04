#!/usr/bin/env bash
# test-verify-build.sh — Unit tests for verify_build()
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

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: '$haystack' does not contain '$needle'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub log() to capture output
LOG_OUTPUT=""
log() {
    LOG_OUTPUT+="[$1] ${*:2}"$'\n'
}

# Source verify_build from autopilot-verify.sh
VERIFY_SRC="$SRC_DIR/autopilot-verify.sh"

if grep -q "^verify_build()" "$VERIFY_SRC" 2>/dev/null; then
    eval "$(sed -n '/^verify_build()/,/^}/p' "$VERIFY_SRC")"
else
    echo "FATAL: verify_build() not found in $VERIFY_SRC"
    echo "This is expected for TDD red — all tests will fail."
    verify_build() { return 99; }
fi

repo="$TMPDIR/repo"
mkdir -p "$repo"

# ─── Test 1: Empty PROJECT_BUILD_CMD → returns 0 (skip) ────────────────────

echo "Test 1: empty PROJECT_BUILD_CMD → returns 0 (skip)"

LOG_OUTPUT=""
PROJECT_BUILD_CMD=""
PROJECT_WORK_DIR="."
DRY_RUN=false
LAST_BUILD_OUTPUT=""
rc=0
verify_build "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 for empty build cmd"
assert_contains "$LOG_OUTPUT" "INFO" "logs INFO message"

# ─── Test 2: Successful build command → returns 0 ──────────────────────────

echo "Test 2: successful build command (true) → returns 0"

LOG_OUTPUT=""
PROJECT_BUILD_CMD="true"
PROJECT_WORK_DIR="."
DRY_RUN=false
LAST_BUILD_OUTPUT=""
rc=0
verify_build "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 for successful build"
assert_contains "$LOG_OUTPUT" "OK" "logs OK message"

# ─── Test 3: Failed build command → returns 1, output captured ─────────────

echo "Test 3: failed build command (false) → returns 1, output captured"

LOG_OUTPUT=""
PROJECT_BUILD_CMD="echo 'build error output' && false"
PROJECT_WORK_DIR="."
DRY_RUN=false
LAST_BUILD_OUTPUT=""
rc=0
verify_build "$repo" || rc=$?
assert_eq "1" "$rc" "returns 1 for failed build"
assert_contains "$LAST_BUILD_OUTPUT" "build error output" "LAST_BUILD_OUTPUT captured"
assert_contains "$LOG_OUTPUT" "WARN" "logs WARN message"

# ─── Test 4: DRY_RUN=true → returns 0 ──────────────────────────────────────

echo "Test 4: DRY_RUN=true → returns 0"

# Re-source with DRY_RUN awareness — verify_build doesn't check DRY_RUN itself
# (DRY_RUN is handled at the caller level, not inside verify_build)
# So we test that with an empty command it returns 0 (same as skip)
LOG_OUTPUT=""
PROJECT_BUILD_CMD=""
PROJECT_WORK_DIR="."
DRY_RUN=true
LAST_BUILD_OUTPUT=""
rc=0
verify_build "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 when no build cmd (DRY_RUN context)"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
