#!/usr/bin/env bash
# test-stall-progress-gate.sh — Tests for minimum-progress gate in stall detection
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

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Stateful stub: returns issues with configurable count sequence
_STUB_RC_SEQ=()
_STUB_CALL=0
_STUB_ISSUE_COUNTS=()
_tier_stub() {
    local rc=${_STUB_RC_SEQ[$_STUB_CALL]:-2}
    TIER_OUTPUT="CRITICAL: stub finding"
    _STUB_CALL=$((_STUB_CALL + 1))
    return "$rc"
}
# Override _count_review_issues to return from sequence
_count_review_issues() {
    local idx=$(( _STUB_CALL - 1 ))
    echo "${_STUB_ISSUE_COUNTS[$idx]:-0}"
}
_reset_stubs() {
    _STUB_RC_SEQ=(); _STUB_CALL=0; _STUB_ISSUE_COUNTS=()
    TIER_OUTPUT=""; LAST_CR_STATUS=""
}

# Common config for all stall tests
FORCE_ADVANCE_ON_REVIEW_STALL=true
CONVERGENCE_STALL_ROUNDS=2
DIMINISHING_RETURNS_THRESHOLD=99
FORCE_ADVANCE_ON_REVIEW_ERROR=false
FORCE_ADVANCE_ON_DIMINISHING_RETURNS=false
STALL_ADVANCE_MAX_ISSUES=5
STALL_ADVANCE_MAX_REMAINING_PCT=50

# ─── Test 1: count=8, initial=13 → blocked (ratio=0.62>0.50, count=8>5) ──
echo "Test: Stall progress gate — blocked (both bad)"

_reset_stubs
_STUB_RC_SEQ=(1 1 1)
_STUB_ISSUE_COUNTS=(13 8 8)  # round1=13, round2=8, round3=8; stall fires round3; initial=13, remaining=8; 8>5 AND 8*100/13=61>50 → blocked
_tier_coderabbit_cli() { _tier_stub; }

repo="$TMPDIR_TEST/repo1"
mkdir -p "$repo/specs/001-test"
echo "- [x] Task 1" > "$repo/specs/001-test/tasks.md"

rc=0; _review_fix_loop "$repo" "main" "001" "test" "001-test" "cli" 5 "/dev/null" "" || rc=$?
assert_eq "1" "$rc" "blocked: count=8>5, ratio=62%>50% → halted (rc=1)"
# Verify NO marker written (halted, not force-advanced)
rc=0; grep -qF "<!-- REVIEW_FORCE_SKIPPED -->" "$repo/specs/001-test/tasks.md" && rc=1 || rc=0
assert_eq "0" "$rc" "blocked: no REVIEW_FORCE_SKIPPED marker"

# ─── Test 2: count=2, initial=5 → advances (count<=5, gate passes) ───────
echo "Test: Stall progress gate — advances (count low)"

_reset_stubs
_STUB_RC_SEQ=(1 1 1)
_STUB_ISSUE_COUNTS=(5 2 2)  # round1=5, round2=2, round3=2; stall fires round3; initial=5, remaining=2; 2<=5 → AND fails → force-advance
_tier_coderabbit_cli() { _tier_stub; }

repo2="$TMPDIR_TEST/repo2"
mkdir -p "$repo2/specs/002-test"
echo "- [x] Task 1" > "$repo2/specs/002-test/tasks.md"

rc=0; _review_fix_loop "$repo2" "main" "002" "test" "002-test" "cli" 5 "/dev/null" "" || rc=$?
assert_eq "3" "$rc" "advances: count=2<=5 → force-advanced (rc=3)"
rc=0; grep -qF "<!-- REVIEW_FORCE_SKIPPED -->" "$repo2/specs/002-test/tasks.md" || rc=$?
assert_eq "0" "$rc" "advances: REVIEW_FORCE_SKIPPED marker written"

# ─── Test 3: count=6, initial=20 → advances (ratio=0.30<0.50, good progress)
echo "Test: Stall progress gate — advances (good ratio)"

_reset_stubs
_STUB_RC_SEQ=(1 1 1)
_STUB_ISSUE_COUNTS=(20 6 6)  # round1=20, round2=6, round3=6; stall fires round3; initial=20, remaining=6; 6>5 but 6*100/20=30<50 → AND fails → force-advance
_tier_coderabbit_cli() { _tier_stub; }

repo3="$TMPDIR_TEST/repo3"
mkdir -p "$repo3/specs/003-test"
echo "- [x] Task 1" > "$repo3/specs/003-test/tasks.md"

rc=0; _review_fix_loop "$repo3" "main" "003" "test" "003-test" "cli" 5 "/dev/null" "" || rc=$?
assert_eq "3" "$rc" "advances: ratio=30%<50% → force-advanced (rc=3)"
rc=0; grep -qF "<!-- REVIEW_FORCE_SKIPPED -->" "$repo3/specs/003-test/tasks.md" || rc=$?
assert_eq "0" "$rc" "advances: REVIEW_FORCE_SKIPPED marker written"

# ─── Test 4: count=8, initial=10, ratio=80%>50%, count=8>5 → blocked ─────
echo "Test: Stall progress gate — blocked (high count + poor ratio)"

_reset_stubs
_STUB_RC_SEQ=(1 1 1)
_STUB_ISSUE_COUNTS=(10 8 8)  # round1=10, round2=8, round3=8; stall fires round3; initial=10, remaining=8; 8>5 AND 8*100/10=80>50 → blocked
_tier_coderabbit_cli() { _tier_stub; }

repo4="$TMPDIR_TEST/repo4"
mkdir -p "$repo4/specs/004-test"
echo "- [x] Task 1" > "$repo4/specs/004-test/tasks.md"

rc=0; _review_fix_loop "$repo4" "main" "004" "test" "004-test" "cli" 5 "/dev/null" "" || rc=$?
assert_eq "1" "$rc" "blocked: count=8>5, ratio=80%>50% → halted"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Stall Progress Gate Tests: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then exit 1; fi
