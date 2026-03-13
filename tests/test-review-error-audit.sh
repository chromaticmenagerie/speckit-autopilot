#!/usr/bin/env bash
# test-review-error-audit.sh — Tests for REVIEW_FORCE_SKIPPED marker audit trail
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────
TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $msg: expected '$expected', got '$actual'"
    fi
}

# ─── Stubs ──────────────────────────────────────────────────────────────────
log() { :; }
_emit_event() { :; }
invoke_claude() { return 0; }
prompt_review_fix() { echo "fix prompt stub"; }
prompt_self_review() { echo "self review prompt stub"; }
prompt_self_review_chunk() { echo "chunk prompt stub"; }
ensure_coderabbit_config() { :; }

SCRIPT_DIR="$SRC_DIR"
source "$SRC_DIR/autopilot-review-helpers.sh"
source "$SRC_DIR/autopilot-review.sh"

# Temp dir for tasks files
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ─── Stateful Stub Infrastructure ──────────────────────────────────────────
_STUB_RC_SEQ=()
_STUB_CALL=0
_tier_stub() {
    local rc=${_STUB_RC_SEQ[$_STUB_CALL]:-2}
    TIER_OUTPUT="CRITICAL: stub finding"
    _STUB_CALL=$((_STUB_CALL + 1))
    return "$rc"
}
_reset_stubs() {
    _STUB_RC_SEQ=(); _STUB_CALL=0; TIER_OUTPUT=""; LAST_CR_STATUS=""
}

# ─── Test 1: Marker written when all tiers fail + force-advance ─────────
echo "Test: REVIEW_FORCE_SKIPPED on all-tiers-fail"

_reset_stubs
_STUB_RC_SEQ=(2 2)
_tier_coderabbit_cli() { _tier_stub; }
_tier_claude_self_review() { _tier_stub; }
REVIEW_TIER_ORDER="cli,self"
FORCE_ADVANCE_ON_REVIEW_ERROR=true

# Set up tasks file
repo="$TMPDIR_TEST/repo1"
mkdir -p "$repo/specs/001-test"
echo "- [x] Task 1" > "$repo/specs/001-test/tasks.md"

rc=0; _tiered_review "$repo" "main" "001" "test" "001-test" "/dev/null" || rc=$?
assert_eq "0" "$rc" "all-tiers-fail+force returns 0"
rc=0; grep -qF "<!-- REVIEW_FORCE_SKIPPED -->" "$repo/specs/001-test/tasks.md" || rc=$?
assert_eq "0" "$rc" "marker written to tasks.md on all-tiers-fail"

# ─── Test 2: Marker written on max-rounds-exhausted force-advance ───────
echo "Test: REVIEW_FORCE_SKIPPED on max-rounds-exhausted"

_reset_stubs
_STUB_RC_SEQ=(1 1)
_tier_coderabbit_cli() { _tier_stub; }
FORCE_ADVANCE_ON_REVIEW_ERROR=true
FORCE_ADVANCE_ON_REVIEW_STALL=false
CONVERGENCE_STALL_ROUNDS=99
DIMINISHING_RETURNS_THRESHOLD=99

repo2="$TMPDIR_TEST/repo2"
mkdir -p "$repo2/specs/002-test"
echo "- [x] Task 1" > "$repo2/specs/002-test/tasks.md"

rc=0; _review_fix_loop "$repo2" "main" "002" "test" "002-test" "cli" 2 "/dev/null" || rc=$?
assert_eq "3" "$rc" "max-rounds+force returns 3"
rc=0; grep -qF "<!-- REVIEW_FORCE_SKIPPED -->" "$repo2/specs/002-test/tasks.md" || rc=$?
assert_eq "0" "$rc" "marker written to tasks.md on max-rounds-exhausted"

# ─── Test 3: Marker written on stall force-advance ──────────────────────
echo "Test: REVIEW_FORCE_SKIPPED on stall force-advance"

_reset_stubs
# Two rounds returning issues with same count → stall
_STUB_RC_SEQ=(1 1)
_STUB_ISSUE_COUNT=3
_count_review_issues() { echo "$_STUB_ISSUE_COUNT"; }
_tier_coderabbit_cli() { _tier_stub; }
FORCE_ADVANCE_ON_REVIEW_ERROR=false
FORCE_ADVANCE_ON_REVIEW_STALL=true
CONVERGENCE_STALL_ROUNDS=2
DIMINISHING_RETURNS_THRESHOLD=99
STALL_ADVANCE_MAX_ISSUES=5   # 3 <= 5, so progress gate passes

repo3="$TMPDIR_TEST/repo3"
mkdir -p "$repo3/specs/003-test"
echo "- [x] Task 1" > "$repo3/specs/003-test/tasks.md"

rc=0; _review_fix_loop "$repo3" "main" "003" "test" "003-test" "cli" 5 "/dev/null" || rc=$?
assert_eq "3" "$rc" "stall+force returns 3"
rc=0; grep -qF "<!-- REVIEW_FORCE_SKIPPED -->" "$repo3/specs/003-test/tasks.md" || rc=$?
assert_eq "0" "$rc" "marker written to tasks.md on stall force-advance"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Review Error Audit Tests: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then exit 1; fi
