#!/usr/bin/env bash
# test-prompt-changes.sh — Tests for Wave 3 prompt additions
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL $msg: expected to contain '$needle'"
    fi
}

# Stub dependencies required by sourcing
log() { :; }
MERGE_TARGET="main"
BASE_BRANCH="main"
STUB_ENFORCEMENT_LEVEL="warn"
HAS_FRONTEND="false"
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
source "$SRC_DIR/autopilot-prompts.sh"

echo "=== prompt_review deferred exclusion ==="
review_out=$(prompt_review "E1" "test" "/tmp" "test-short")
assert_contains "$review_out" "deferred tasks (- [-] in tasks.md)" "deferred exclusion text present"
assert_contains "$review_out" "flag deferred-task code with side effects" "side effects MEDIUM text present"

echo ""
echo "=== prompt_verify_requirements plan.md ref ==="
vr_out=$(prompt_verify_requirements "E1" "test" "/tmp" "test-short" "/tmp/ev" "/tmp/fi" "1" "3")
assert_contains "$vr_out" "plan.md exists, also read it" "verify_requirements plan.md ref present"

echo ""
echo "=== prompt_requirements_fix plan.md ref ==="
rf_out=$(prompt_requirements_fix "E1" "test" "/tmp" "test-short" "/tmp/fi" "FR-001: NOT_FOUND")
assert_contains "$rf_out" "plan.md exists, also read it" "requirements_fix plan.md ref present"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
