#!/usr/bin/env bash
# test-verify-tests-enforcement.sh — Tests for verify_tests() enforcement parameter
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

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: '$haystack' should NOT contain '$needle'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Stub log() to capture output
LOG_OUTPUT=""
log() {
    LOG_OUTPUT+="[$1] ${*:2}"$'\n'
}

# Source verify_tests from autopilot-verify.sh
VERIFY_SRC="$SRC_DIR/autopilot-verify.sh"

if grep -q "^verify_tests()" "$VERIFY_SRC" 2>/dev/null; then
    eval "$(sed -n '/^verify_tests()/,/^}/p' "$VERIFY_SRC")"
else
    echo "FATAL: verify_tests() not found in $VERIFY_SRC"
    verify_tests() { return 99; }
fi

# Create a repo dir with a Go test file containing t.Skip()
repo="$TMPDIR_ROOT/repo"
mkdir -p "$repo"

# Minimal test file with t.Skip() stub
cat > "$repo/handler_test.go" <<'GOEOF'
package main

import "testing"

func TestHandler(t *testing.T) {
    t.Skip("not implemented yet")
}
GOEOF

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== verify_tests() enforcement parameter tests ==="

# ─── Test 1: enforcement=error returns 1 on stubs (current behavior) ────────

echo "Test 1: enforcement=error returns 1 when stubs found"

LOG_OUTPUT=""
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "error" || rc=$?
assert_eq "1" "$rc" "returns 1 with enforcement=error"
assert_contains "$LOG_OUTPUT" "ERROR" "logs ERROR for stubs"
assert_contains "$LOG_OUTPUT" "t.Skip()" "mentions t.Skip() in log"

# ─── Test 2: enforcement=warn logs stubs but returns 0 ──────────────────────

echo "Test 2: enforcement=warn logs stubs but returns 0"

LOG_OUTPUT=""
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "warn" || rc=$?
assert_eq "0" "$rc" "returns 0 with enforcement=warn"
assert_contains "$LOG_OUTPUT" "WARN" "logs WARN for stubs"
assert_contains "$LOG_OUTPUT" "t.Skip()" "mentions t.Skip() in warn log"

# ─── Test 3: enforcement=off skips stub detection entirely ───────────────────

echo "Test 3: enforcement=off skips stub detection"

LOG_OUTPUT=""
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "off" || rc=$?
assert_eq "0" "$rc" "returns 0 with enforcement=off"
assert_not_contains "$LOG_OUTPUT" "t.Skip()" "no t.Skip() mention with off"
assert_contains "$LOG_OUTPUT" "Tests pass" "logs Tests pass"

# ─── Test 4: no second arg defaults to warn behavior ────────────────────────

echo "Test 4: no enforcement arg defaults to warn (returns 0, logs WARN)"

LOG_OUTPUT=""
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 with default (warn)"
assert_contains "$LOG_OUTPUT" "WARN" "logs WARN with default"

# ─── Test 5: no stubs → all enforcement levels return 0 ─────────────────────

echo "Test 5: no stubs present → returns 0 regardless of enforcement"

clean_repo="$TMPDIR_ROOT/clean"
mkdir -p "$clean_repo"
# Test file WITHOUT t.Skip()
cat > "$clean_repo/handler_test.go" <<'GOEOF'
package main

import "testing"

func TestHandler(t *testing.T) {
    if 1 != 1 {
        t.Fatal("math is broken")
    }
}
GOEOF

for level in off warn error; do
    LOG_OUTPUT=""
    PROJECT_TEST_CMD="true"
    PROJECT_WORK_DIR="."
    LAST_TEST_OUTPUT=""
    rc=0
    verify_tests "$clean_repo" "$level" || rc=$?
    assert_eq "0" "$rc" "returns 0 with enforcement=$level and no stubs"
done

# ─── Test 6: verify_ci passes STUB_ENFORCEMENT_LEVEL to verify_tests ────────

echo "Test 6: verify_ci call site passes STUB_ENFORCEMENT_LEVEL"
call_line=$(grep -n 'verify_tests.*STUB_ENFORCEMENT' "$VERIFY_SRC" || true)
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -n "$call_line" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ verify_ci passes STUB_ENFORCEMENT_LEVEL to verify_tests"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ verify_ci should pass STUB_ENFORCEMENT_LEVEL to verify_tests"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
