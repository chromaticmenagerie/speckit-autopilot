#!/usr/bin/env bash
# test-clarify-tracking.sh — Tests for clarify round tracking, event emission, and prompt changes
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL $msg: expected '$expected', got '$actual'"
    fi
}

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

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL $msg: expected NOT to contain '$needle'"
    fi
}

# ─── Stub dependencies ────────────────────────────────────────────────────────

log() { :; }
MERGE_TARGET="main"
BASE_BRANCH="main"
STUB_ENFORCEMENT_LEVEL="warn"
HAS_FRONTEND="false"
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
source "$SRC_DIR/autopilot-prompts.sh"

# ─── Item 1: PHASE_MAX_RETRIES[clarify] = 8 ──────────────────────────────────

echo "=== Item 1: clarify max retries ==="

clarify_max=$(grep '^\s*\[clarify\]=[0-9]' "$SRC_DIR/autopilot.sh" | grep -oE '[0-9]+')
assert_eq "8" "$clarify_max" "clarify max retries is 8"

# ─── Item 1: MAX_ITERATIONS default = 70 ─────────────────────────────────────

echo ""
echo "=== Item 1: MAX_ITERATIONS default ==="

max_iter_line=$(grep 'max_iter=\${MAX_ITERATIONS:-' "$SRC_DIR/autopilot.sh")
assert_contains "$max_iter_line" "MAX_ITERATIONS:-70" "MAX_ITERATIONS default is 70"

# ─── Item 1: Warning threshold = 20 ──────────────────────────────────────────

echo ""
echo "=== Item 1: Warning threshold ==="

warn_line=$(grep 'lt 20' "$SRC_DIR/autopilot.sh" || echo "")
assert_contains "$warn_line" "lt 20" "warning threshold is 20"

# ─── Item 1: prompt_clarify says 8 rounds ────────────────────────────────────

echo ""
echo "=== Item 1: prompt_clarify max rounds text ==="

out=$(prompt_clarify "E1" "test" "/tmp/epic" "/tmp" "/tmp/specs" "1" "8")
assert_contains "$out" "maximum of 8 rounds" "prompt says 8 rounds"

# ─── Item 3: VERIFY_FINDINGS instruction ─────────────────────────────────────

echo ""
echo "=== Item 3: VERIFY_FINDINGS instruction ==="

out=$(prompt_clarify "E1" "test" "/tmp/epic" "/tmp" "/tmp/specs" "1" "8")
assert_contains "$out" "VERIFY_FINDINGS" "prompt mentions VERIFY_FINDINGS"
assert_contains "$out" "prioritise addressing those issues first" "prioritise text present"
assert_contains "$out" "remove the resolved VERIFY_FINDINGS comment block" "removal instruction present"

# ─── Item 5e: prompt_clarify cycle info in commit messages ────────────────────

echo ""
echo "=== Item 5e: prompt_clarify cycle info ==="

# With cycle info
out_with=$(prompt_clarify "E1" "test" "/tmp/epic" "/tmp" "/tmp/specs" "2" "8" "5" "2")
assert_contains "$out_with" "cycle 2, total 5" "commit msg includes cycle info"

# Without cycle info (backward compat)
out_without=$(prompt_clarify "E1" "test" "/tmp/epic" "/tmp" "/tmp/specs" "2" "8")
assert_not_contains "$out_without" "cycle" "no cycle info when args omitted"

# ─── Item 4: _emit_clarify_summary function ──────────────────────────────────

echo ""
echo "=== Item 4: _emit_clarify_summary ==="

# Source the function
eval "$(sed -n '/_emit_clarify_summary()/,/^}/p' "$SRC_DIR/autopilot.sh")"

tmp_root=$(mktemp -d)
mkdir -p "$tmp_root/.specify/logs"

_emit_clarify_summary "$tmp_root" "E1" "6" "2" "false"

events_file="$tmp_root/.specify/logs/events.jsonl"
assert_eq "1" "$(wc -l < "$events_file" | tr -d ' ')" "one event line written"

event_json=$(cat "$events_file")
assert_contains "$event_json" '"event":"clarify_summary"' "event name correct"
assert_contains "$event_json" '"epic":"E1"' "epic correct"
assert_contains "$event_json" '"rounds":6' "rounds correct"
assert_contains "$event_json" '"cv_rejections":2' "cv_rejections correct"
assert_contains "$event_json" '"force_advanced":false' "force_advanced correct"
assert_contains "$event_json" '"timestamp"' "timestamp present"

# Test force_advanced=true
_emit_clarify_summary "$tmp_root" "E2" "3" "0" "true"
line2=$(tail -1 "$events_file")
assert_contains "$line2" '"force_advanced":true' "force_advanced true works"

rm -rf "$tmp_root"

# ─── Item 5: Cumulative variable declarations ────────────────────────────────

echo ""
echo "=== Item 5: Cumulative variables declared ==="

assert_contains "$(grep 'clarify_total_rounds' "$SRC_DIR/autopilot.sh")" "clarify_total_rounds=0" "clarify_total_rounds declared"
assert_contains "$(grep 'clarify_cycle=' "$SRC_DIR/autopilot.sh" | head -1)" "clarify_cycle=1" "clarify_cycle declared"
assert_contains "$(grep 'clarify_cv_rejections' "$SRC_DIR/autopilot.sh" | head -1)" "clarify_cv_rejections=0" "clarify_cv_rejections declared"

# ─── Item 5b: clarify_total_rounds++ in clarify branch ───────────────────────

echo ""
echo "=== Item 5b: Increment on clarify round ==="

inc_line=$(grep -A1 'clarify_total_rounds++' "$SRC_DIR/autopilot.sh" || echo "")
assert_contains "$inc_line" "clarify_total_rounds++" "clarify_total_rounds incremented"

# ─── Item 5c: CV→clarify transition tracking ─────────────────────────────────

echo ""
echo "=== Item 5c: CV→clarify tracking ==="

cv_block=$(grep -A2 'prev_state.*clarify-verify.*new_state.*clarify' "$SRC_DIR/autopilot.sh" || echo "")
assert_contains "$cv_block" "clarify_cycle++" "clarify_cycle incremented on CV→clarify"
assert_contains "$cv_block" "clarify_cv_rejections++" "cv_rejections incremented on CV→clarify"

# ─── Item 5d: Log messages include cumulative info ───────────────────────────

echo ""
echo "=== Item 5d: Log messages with cumulative ==="

log_line=$(grep 'cycle.*total round.*observations remain' "$SRC_DIR/autopilot.sh" || echo "")
assert_contains "$log_line" "cycle \$clarify_cycle" "log includes cycle"
assert_contains "$log_line" "total round \$clarify_total_rounds" "log includes total rounds"

force_log=$(grep 'force-advance clarify after' "$SRC_DIR/autopilot.sh" | head -1 || echo "")
assert_contains "$force_log" "cycle \$clarify_cycle" "force-advance log includes cycle"

# ─── Analyze prompt unchanged ─────────────────────────────────────────────────

echo ""
echo "=== Analyze prompt still says 5 rounds ==="

analyze_line=$(grep 'maximum of 5 rounds' "$SRC_DIR/autopilot-prompts.sh" || echo "")
assert_contains "$analyze_line" "maximum of 5 rounds" "analyze still says 5 rounds"

# ─── Results ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
