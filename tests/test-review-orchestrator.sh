#!/usr/bin/env bash
# test-review-orchestrator.sh — Unit tests for _tiered_review orchestrator
# and _review_fix_loop convergence loop.
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

# ─── Stubs (BEFORE sourcing) ────────────────────────────────────────────────

log() { :; }
_emit_event() { :; }
invoke_claude() { return 0; }
prompt_review_fix() { echo "fix prompt stub"; }
prompt_self_review() { echo "self review prompt stub"; }
prompt_self_review_chunk() { echo "chunk prompt stub"; }
ensure_coderabbit_config() { :; }

# Point SCRIPT_DIR to src/ so autopilot-review.sh can source its helpers
SCRIPT_DIR="$SRC_DIR"

# Source review helpers + review orchestrator
source "$SRC_DIR/autopilot-review-helpers.sh"
source "$SRC_DIR/autopilot-review.sh"

# ─── Stateful Stub Infrastructure ───────────────────────────────────────────

_STUB_RC_SEQ=()
_STUB_CALL=0
_tier_stub() {
    local rc=${_STUB_RC_SEQ[$_STUB_CALL]:-2}
    TIER_OUTPUT="CRITICAL: stub finding"
    _STUB_CALL=$((_STUB_CALL + 1))
    return "$rc"
}

_reset_stubs() {
    _STUB_RC_SEQ=()
    _STUB_CALL=0
    TIER_OUTPUT=""
    LAST_CR_STATUS=""
}

# ─── Tests: _tiered_review orchestrator ─────────────────────────────────────

echo "Test: _tiered_review orchestrator"

# Test 1: Tier fallthrough (cli errors, codex errors, self succeeds)
_reset_stubs
_STUB_RC_SEQ=(2 2 0)
_tier_coderabbit_cli() { _tier_stub; }
_tier_codex() { _tier_stub; }
_tier_claude_self_review() { _tier_stub; }
REVIEW_TIER_ORDER="cli,codex,self"
FORCE_ADVANCE_ON_REVIEW_ERROR=false

rc=0; _tiered_review "/tmp" "main" "001" "test" "test-short" "/dev/null" || rc=$?
assert_eq "0" "$rc" "fallthrough: returns 0 when self tier succeeds"
echo "$LAST_CR_STATUS" | grep -q "self" && _found_self=0 || _found_self=1
assert_eq "0" "$_found_self" "fallthrough: LAST_CR_STATUS contains 'self'"

# Test 2: Stop on clean (first tier clean)
_reset_stubs
_STUB_RC_SEQ=(0)
_tier_coderabbit_cli() { _tier_stub; }
REVIEW_TIER_ORDER="cli"
FORCE_ADVANCE_ON_REVIEW_ERROR=false

rc=0; _tiered_review "/tmp" "main" "001" "test" "test-short" "/dev/null" || rc=$?
assert_eq "0" "$rc" "stop-on-clean: returns 0"
echo "$LAST_CR_STATUS" | grep -q "cli" && _found_cli=0 || _found_cli=1
assert_eq "0" "$_found_cli" "stop-on-clean: LAST_CR_STATUS contains 'cli'"

# Test 3: All tiers fail (no force-advance)
_reset_stubs
_STUB_RC_SEQ=(2 2)
_tier_coderabbit_cli() { _tier_stub; }
_tier_claude_self_review() { _tier_stub; }
REVIEW_TIER_ORDER="cli,self"
FORCE_ADVANCE_ON_REVIEW_ERROR=false

rc=0; _tiered_review "/tmp" "main" "001" "test" "test-short" "/dev/null" || rc=$?
assert_eq "1" "$rc" "all-tiers-fail: returns 1"
assert_eq "all tiers failed" "$LAST_CR_STATUS" "all-tiers-fail: LAST_CR_STATUS"

# Test 4: All tiers fail + force-advance
_reset_stubs
_STUB_RC_SEQ=(2 2)
_tier_coderabbit_cli() { _tier_stub; }
_tier_claude_self_review() { _tier_stub; }
REVIEW_TIER_ORDER="cli,self"
FORCE_ADVANCE_ON_REVIEW_ERROR=true

rc=0; _tiered_review "/tmp" "main" "001" "test" "test-short" "/dev/null" || rc=$?
assert_eq "0" "$rc" "all-tiers-fail+force: returns 0"

# ─── Tests: _review_fix_loop convergence ────────────────────────────────────

echo ""
echo "Test: _review_fix_loop convergence"

# Test 5: Clean on round 2
_reset_stubs
_STUB_RC_SEQ=(1 0)
_tier_coderabbit_cli() { _tier_stub; }
FORCE_ADVANCE_ON_REVIEW_ERROR=false
FORCE_ADVANCE_ON_REVIEW_STALL=false
CONVERGENCE_STALL_ROUNDS=2
DIMINISHING_RETURNS_THRESHOLD=99

rc=0; _review_fix_loop "/tmp" "main" "001" "test" "test-short" "cli" 3 "/dev/null" || rc=$?
assert_eq "0" "$rc" "clean-round-2: returns 0"
echo "$LAST_CR_STATUS" | grep -q "clean" && _found_clean=0 || _found_clean=1
assert_eq "0" "$_found_clean" "clean-round-2: LAST_CR_STATUS contains 'clean'"

# Test 6: Max rounds exhausted
_reset_stubs
_STUB_RC_SEQ=(1 1)
_tier_coderabbit_cli() { _tier_stub; }
FORCE_ADVANCE_ON_REVIEW_ERROR=false
FORCE_ADVANCE_ON_REVIEW_STALL=false
CONVERGENCE_STALL_ROUNDS=99
DIMINISHING_RETURNS_THRESHOLD=99

rc=0; _review_fix_loop "/tmp" "main" "001" "test" "test-short" "cli" 2 "/dev/null" || rc=$?
assert_eq "1" "$rc" "max-rounds-exhausted: returns 1"
echo "$LAST_CR_STATUS" | grep -q "halted" && _found_halt=0 || _found_halt=1
assert_eq "0" "$_found_halt" "max-rounds-exhausted: LAST_CR_STATUS contains 'halted'"

# Test 7: Max rounds + force-advance
_reset_stubs
_STUB_RC_SEQ=(1 1)
_tier_coderabbit_cli() { _tier_stub; }
FORCE_ADVANCE_ON_REVIEW_ERROR=true
FORCE_ADVANCE_ON_REVIEW_STALL=false
CONVERGENCE_STALL_ROUNDS=99
DIMINISHING_RETURNS_THRESHOLD=99

rc=0; _review_fix_loop "/tmp" "main" "001" "test" "test-short" "cli" 2 "/dev/null" || rc=$?
assert_eq "3" "$rc" "max-rounds+force: returns 3 (force-advance, fall through to next tier)"
echo "$LAST_CR_STATUS" | grep -q "force-advanced" && _found_force=0 || _found_force=1
assert_eq "0" "$_found_force" "max-rounds+force: LAST_CR_STATUS contains 'force-advanced'"

# Test 8: Tier error mid-loop
_reset_stubs
_STUB_RC_SEQ=(1 2)
_tier_coderabbit_cli() { _tier_stub; }
FORCE_ADVANCE_ON_REVIEW_ERROR=false
FORCE_ADVANCE_ON_REVIEW_STALL=false
CONVERGENCE_STALL_ROUNDS=99
DIMINISHING_RETURNS_THRESHOLD=99

rc=0; _review_fix_loop "/tmp" "main" "001" "test" "test-short" "cli" 3 "/dev/null" || rc=$?
assert_eq "2" "$rc" "tier-error-mid-loop: returns 2 (signals caller to try next tier)"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "================================"
echo "Review Orchestrator Tests: $TESTS_PASSED/$TESTS_RUN passed"
echo "================================"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
