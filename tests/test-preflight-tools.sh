#!/usr/bin/env bash
# test-preflight-tools.sh — Unit tests for verify_preflight_tools()
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

# Extract verify_preflight_tools from autopilot-lib.sh (or autopilot-verify.sh if it exists)
VERIFY_SRC="$SRC_DIR/autopilot-lib.sh"
[[ -f "$SRC_DIR/autopilot-verify.sh" ]] && VERIFY_SRC="$SRC_DIR/autopilot-verify.sh"

if grep -q "^verify_preflight_tools()" "$VERIFY_SRC" 2>/dev/null; then
    eval "$(sed -n '/^verify_preflight_tools()/,/^}/p' "$VERIFY_SRC")"
else
    echo "FATAL: verify_preflight_tools() not found in $VERIFY_SRC"
    echo "This is expected for TDD red — all tests will fail."
    verify_preflight_tools() { return 99; }
fi

repo="$TMPDIR/repo"
mkdir -p "$repo"

# ─── Test 1: Empty PROJECT_PREFLIGHT_TOOLS → returns 0, logs INFO ──────────

echo "Test 1: empty PROJECT_PREFLIGHT_TOOLS → returns 0, logs INFO"

LOG_OUTPUT=""
PROJECT_PREFLIGHT_TOOLS=""
DRY_RUN=false
rc=0
verify_preflight_tools "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 for empty tools"
assert_contains "$LOG_OUTPUT" "INFO" "logs INFO message"

# ─── Test 2: Valid tools → returns 0 ────────────────────────────────────────

echo "Test 2: valid tools (bash) → returns 0"

LOG_OUTPUT=""
PROJECT_PREFLIGHT_TOOLS="bash"
DRY_RUN=false
rc=0
verify_preflight_tools "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 for valid tool"

# ─── Test 3: Missing tool → returns 1, logs ERROR with tool name ────────────

echo "Test 3: missing tool → returns 1, logs ERROR"

LOG_OUTPUT=""
PROJECT_PREFLIGHT_TOOLS="nonexistent_xyz"
DRY_RUN=false
rc=0
verify_preflight_tools "$repo" || rc=$?
assert_eq "1" "$rc" "returns 1 for missing tool"
assert_contains "$LOG_OUTPUT" "ERROR" "logs ERROR"
assert_contains "$LOG_OUTPUT" "nonexistent_xyz" "ERROR mentions missing tool name"

# ─── Test 4: DRY_RUN=true → returns 0, logs [DRY RUN] ──────────────────────

echo "Test 4: DRY_RUN=true → returns 0, logs DRY RUN"

LOG_OUTPUT=""
PROJECT_PREFLIGHT_TOOLS="nonexistent_xyz"
DRY_RUN=true
rc=0
verify_preflight_tools "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 in dry run mode"
assert_contains "$LOG_OUTPUT" "[DRY RUN]" "logs DRY RUN marker"

# ─── Test 5: Mix valid + missing → returns 1, lists only missing ────────────

echo "Test 5: mix valid + missing → returns 1, lists only missing"

LOG_OUTPUT=""
PROJECT_PREFLIGHT_TOOLS="bash nonexistent_xyz"
DRY_RUN=false
rc=0
verify_preflight_tools "$repo" || rc=$?
assert_eq "1" "$rc" "returns 1 for mixed tools"
assert_contains "$LOG_OUTPUT" "nonexistent_xyz" "mentions missing tool"
# bash should NOT appear in the error output about missing tools
if [[ "$LOG_OUTPUT" == *"ERROR"*"bash"* ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ should not list 'bash' as missing"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ does not list 'bash' as missing"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
