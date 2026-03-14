#!/usr/bin/env bash
# test-circuit-breaker.sh — Unit tests for circuit breaker (_cb_gate, _cb_record_failure, _cb_record_success)
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

# ─── Setup ──────────────────────────────────────────────────────────────────

# Stubs
log() { :; }

# Mock sleep as no-op to avoid blocking tests
sleep() { :; }

# Extract circuit breaker functions and globals from autopilot-lib.sh
eval "$(sed -n '/^# ─── Circuit Breaker State/,/^# ─── /{ /^# ─── [^C]/d; p; }' "$SRC_DIR/autopilot-lib.sh")"

# Helper to reset CB state between tests
_cb_reset() {
    _CB_CONSECUTIVE_FAILURES=0
    _CB_CUMULATIVE_WAIT=0
    _CB_COOLDOWN=30
    _CB_MAX_CUMULATIVE_WAIT=86400
}

# ─── Case 1: CB stays closed on fewer than 3 failures ──────────────────────

echo "Case 1: CB stays closed on fewer than 3 failures"

_cb_reset
_cb_record_failure
_cb_record_failure

rc=0
_cb_gate || rc=$?
assert_eq "0" "$rc" "gate returns 0 with 2 failures"
assert_eq "2" "$_CB_CONSECUTIVE_FAILURES" "failure count is 2"

# ─── Case 2: CB opens after 3 consecutive failures ─────────────────────────

echo ""
echo "Case 2: CB opens after 3 consecutive failures"

_cb_reset
_cb_record_failure
_cb_record_failure
_cb_record_failure

assert_eq "3" "$_CB_CONSECUTIVE_FAILURES" "failure count is 3"

rc=0
_cb_gate || rc=$?
assert_eq "0" "$rc" "gate returns 0 (backs off, does not give up)"

# ─── Case 3: CB resets on success ──────────────────────────────────────────

echo ""
echo "Case 3: CB resets on success"

_cb_reset
_cb_record_failure
_cb_record_failure
_cb_record_failure
_cb_record_success

assert_eq "0" "$_CB_CONSECUTIVE_FAILURES" "failures reset to 0"
assert_eq "0" "$_CB_CUMULATIVE_WAIT" "cumulative wait reset to 0"
assert_eq "30" "$_CB_COOLDOWN" "cooldown reset to 30"

# ─── Case 4: Cooldown escalation ───────────────────────────────────────────

echo ""
echo "Case 4: Cooldown escalation"

_cb_reset
_CB_CONSECUTIVE_FAILURES=3
_CB_COOLDOWN=30

_cb_gate  # sleeps 30 (mocked), cooldown doubles to 60
assert_eq "60" "$_CB_COOLDOWN" "cooldown escalates 30 → 60"

_cb_gate  # sleeps 60 (mocked), cooldown doubles to 120
assert_eq "120" "$_CB_COOLDOWN" "cooldown escalates 60 → 120"

_cb_gate  # sleeps 120 (mocked), cooldown doubles to 240
assert_eq "240" "$_CB_COOLDOWN" "cooldown escalates 120 → 240"

_cb_gate  # sleeps 240 (mocked), would double to 480 but capped at 300
assert_eq "300" "$_CB_COOLDOWN" "cooldown caps at 300"

# ─── Case 5: Give-up after max cumulative wait ─────────────────────────────

echo ""
echo "Case 5: Give-up after max cumulative wait"

_cb_reset
_CB_CONSECUTIVE_FAILURES=3
_CB_CUMULATIVE_WAIT=86400

rc=0
_cb_gate || rc=$?
assert_eq "99" "$rc" "gate returns 99 (give up)"

# ─── Case 6: 30-min interval after 20 min cumulative ───────────────────────

echo ""
echo "Case 6: 30-min interval after 20 min cumulative"

_cb_reset
_CB_CONSECUTIVE_FAILURES=3
_CB_CUMULATIVE_WAIT=1200
_CB_COOLDOWN=300

_cb_gate  # sleeps 300 (mocked), cumulative becomes 1500 ≥ 1200, cooldown → 1800
assert_eq "1800" "$_CB_COOLDOWN" "cooldown escalates to 1800 after 20 min cumulative"
assert_eq "1500" "$_CB_CUMULATIVE_WAIT" "cumulative wait updated to 1500"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
