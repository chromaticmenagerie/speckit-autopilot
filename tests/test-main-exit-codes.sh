#!/usr/bin/env bash
# test-main-exit-codes.sh — Verify _rc exit code tracking in main()
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
        echo "  ✗ $msg: '$needle' not found in output"
    fi
}

# ─── Source file for grep-based checks ───────────────────────────────────────

MAIN_SRC="$SRC_DIR/autopilot.sh"

# ─── Test 1: _rc=0 initialization in main() ─────────────────────────────────

echo "Test 1: _rc=0 initialized in main()"
# Find local _rc=0 in main() function body
main_body=$(sed -n '/^main()/,/^}/p' "$MAIN_SRC")
echo "$main_body" | grep -q 'local _rc=0' && result="found" || result="missing"
assert_eq "found" "$result" "local _rc=0 declared in main()"

# ─── Test 2: run_epic failure sets _rc=1 ────────────────────────────────────

echo "Test 2: run_epic failure sets _rc=1"
# After run_epic failure, _rc=1 should be set
# run_epic and "did not complete" are on separate lines, so use grep -A3 on run_epic
epic_fail_block=$(echo "$main_body" | grep -A3 'run_epic' || true)
echo "$epic_fail_block" | grep -q '_rc=1' && result="found" || result="missing"
assert_eq "found" "$result" "run_epic failure path sets _rc=1"

# ─── Test 3: Epic not found sets _rc=1 ──────────────────────────────────────

echo "Test 3: Epic not found sets _rc=1"
not_found_block=$(echo "$main_body" | grep -A1 'Epic.*not found' || true)
echo "$not_found_block" | grep -q '_rc=1' && result="found" || result="missing"
assert_eq "found" "$result" "epic-not-found path sets _rc=1"

# ─── Test 4: run_finalize failure sets _rc=1 ─────────────────────────────────

echo "Test 4: run_finalize failure sets _rc=1"
finalize_block=$(echo "$main_body" | grep -A3 'run_finalize' || true)
echo "$finalize_block" | grep -q '_rc=1' && result="found" || result="missing"
assert_eq "found" "$result" "run_finalize failure path sets _rc=1"

# ─── Test 5: main() returns $_rc ────────────────────────────────────────────

echo "Test 5: main() returns \$_rc"
echo "$main_body" | grep -q 'return \$_rc' && result="found" || result="missing"
assert_eq "found" "$result" "main() ends with return \$_rc"

# ─── Test 6: run_finalize no longer uses || pattern ─────────────────────────

echo "Test 6: finalize uses if/then (not || swallow)"
# Old pattern was: run_finalize "$repo_root" || log ERROR "..."
# New pattern: if ! run_finalize; then ... _rc=1 ... fi
echo "$main_body" | grep -q 'if ! run_finalize' && result="found" || result="missing"
assert_eq "found" "$result" "finalize uses if-not pattern instead of || swallow"

# ─── Test 7: AUTO_REVERT_ON_FAILURE default ─────────────────────────────────

echo "Test 7: AUTO_REVERT_ON_FAILURE defaults to false"
grep -q 'AUTO_REVERT_ON_FAILURE=false' "$MAIN_SRC" && result="found" || result="missing"
assert_eq "found" "$result" "AUTO_REVERT_ON_FAILURE=false default exists"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
