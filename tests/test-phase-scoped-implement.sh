#!/usr/bin/env bash
# test-phase-scoped-implement.sh — Tests for phase-scoped implement prompt (Item 11)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Harness ────────────────────────────────────────────────────────────
PASS=0 FAIL=0
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (needle='$needle' not found)"
        FAIL=$((FAIL + 1))
    fi
}
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (needle='$needle' unexpectedly found)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Setup ───────────────────────────────────────────────────────────────────
AUTOPILOT_LOG=""
BOLD="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM=""
MERGE_TARGET="master"
BASE_BRANCH="master"
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
HAS_FRONTEND="false"
log() { :; }

source "$SRC_DIR/common.sh" 2>/dev/null || true
source "$SRC_DIR/autopilot-prompts.sh"

# ─── Tests ───────────────────────────────────────────────────────────────────
echo "== prompt_implement() phase-scoped tests =="

# Test 1: SCOPE block present when total_phases > 1
echo "Test 1: SCOPE block present when phases > 1"
output=$(prompt_implement "001" "Test Epic" "/tmp/repo" "/tmp/repo/specs/001-test" "2" "3")
assert_contains "SCOPE header present" "$output" "SCOPE: Implement Phase 2 of 3 ONLY."
assert_contains "previous phases note" "$output" "Phases 1-1 are already complete."
assert_contains "focus instruction" "$output" "Focus ONLY on Phase 2 tasks."

# Test 2: SCOPE block absent when phases = 1
echo "Test 2: SCOPE block absent when phases = 1"
output=$(prompt_implement "001" "Test Epic" "/tmp/repo" "/tmp/repo/specs/001-test" "1" "1")
assert_not_contains "no SCOPE header" "$output" "SCOPE: Implement Phase"

# Test 3: First phase of multi-phase shows "first phase" message
echo "Test 3: First phase of multi-phase"
output=$(prompt_implement "001" "Test Epic" "/tmp/repo" "/tmp/repo/specs/001-test" "1" "3")
assert_contains "first phase message" "$output" "This is the first phase."

# Test 4: Default args (no phase params) = no SCOPE block
echo "Test 4: Default args (no phase params)"
output=$(prompt_implement "001" "Test Epic" "/tmp/repo" "/tmp/repo/specs/001-test")
assert_not_contains "no SCOPE with defaults" "$output" "SCOPE: Implement Phase"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
