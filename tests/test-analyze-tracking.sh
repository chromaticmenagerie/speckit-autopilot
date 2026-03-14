#!/usr/bin/env bash
# test-analyze-tracking.sh — Tests for analyze round tracking and event emission
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

# ─── Stub dependencies ────────────────────────────────────────────────────────

log() { :; }

# Source _emit_analyze_summary from autopilot.sh
eval "$(sed -n '/_emit_analyze_summary()/,/^}/p' "$SRC_DIR/autopilot.sh")"

# ─── Item 1: _emit_analyze_summary writes correct JSON ───────────────────────

echo "=== Item 1: _emit_analyze_summary writes correct JSON ==="

tmp_root=$(mktemp -d)
mkdir -p "$tmp_root/.specify/logs"

_emit_analyze_summary "$tmp_root" "E1" "6" "2" "false"

events_file="$tmp_root/.specify/logs/events.jsonl"
assert_eq "1" "$(wc -l < "$events_file" | tr -d ' ')" "one event line written"

event_json=$(cat "$events_file")
assert_contains "$event_json" '"event":"analyze_summary"' "event name is analyze_summary"
assert_contains "$event_json" '"epic":"E1"' "epic correct"
assert_contains "$event_json" '"timestamp"' "timestamp present"

rm -rf "$tmp_root"

# ─── Item 2: Fields are correct types ────────────────────────────────────────

echo ""
echo "=== Item 2: Field types ==="

tmp_root=$(mktemp -d)
mkdir -p "$tmp_root/.specify/logs"

_emit_analyze_summary "$tmp_root" "E2" "4" "1" "false"

events_file="$tmp_root/.specify/logs/events.jsonl"
event_json=$(cat "$events_file")

# rounds and verify_rejections should be numbers (no quotes)
assert_contains "$event_json" '"rounds":4' "rounds is number"
assert_contains "$event_json" '"verify_rejections":1' "verify_rejections is number"
# force_advanced should be boolean (no quotes)
assert_contains "$event_json" '"force_advanced":false' "force_advanced is boolean false"

rm -rf "$tmp_root"

# ─── Item 3: Multiple emissions append correctly ─────────────────────────────

echo ""
echo "=== Item 3: Multiple emissions append ==="

tmp_root=$(mktemp -d)
mkdir -p "$tmp_root/.specify/logs"

_emit_analyze_summary "$tmp_root" "E1" "3" "0" "false"
_emit_analyze_summary "$tmp_root" "E2" "7" "2" "true"
_emit_analyze_summary "$tmp_root" "E3" "1" "0" "false"

events_file="$tmp_root/.specify/logs/events.jsonl"
assert_eq "3" "$(wc -l < "$events_file" | tr -d ' ')" "three event lines written"

line1=$(sed -n '1p' "$events_file")
line2=$(sed -n '2p' "$events_file")
line3=$(sed -n '3p' "$events_file")

assert_contains "$line1" '"epic":"E1"' "first line is E1"
assert_contains "$line2" '"epic":"E2"' "second line is E2"
assert_contains "$line3" '"epic":"E3"' "third line is E3"

rm -rf "$tmp_root"

# ─── Item 4: force_advanced true vs false ─────────────────────────────────────

echo ""
echo "=== Item 4: force_advanced true vs false ==="

tmp_root=$(mktemp -d)
mkdir -p "$tmp_root/.specify/logs"

_emit_analyze_summary "$tmp_root" "E1" "5" "3" "false"
_emit_analyze_summary "$tmp_root" "E2" "5" "3" "true"

events_file="$tmp_root/.specify/logs/events.jsonl"

line1=$(sed -n '1p' "$events_file")
line2=$(sed -n '2p' "$events_file")

assert_contains "$line1" '"force_advanced":false' "force_advanced false"
assert_contains "$line2" '"force_advanced":true' "force_advanced true"

rm -rf "$tmp_root"

# ─── Item 5: Tracking variables declared in run_epic ─────────────────────────

echo ""
echo "=== Item 5: Tracking variables declared ==="

assert_contains "$(grep 'analyze_total_rounds' "$SRC_DIR/autopilot.sh")" "analyze_total_rounds=0" "analyze_total_rounds declared"
assert_contains "$(grep 'analyze_cycle=' "$SRC_DIR/autopilot.sh" | head -1)" "analyze_cycle=1" "analyze_cycle declared"
assert_contains "$(grep 'analyze_verify_rejections' "$SRC_DIR/autopilot.sh" | head -1)" "analyze_verify_rejections=0" "analyze_verify_rejections declared"

# ─── Item 6: analyze_total_rounds++ in retry loop ────────────────────────────

echo ""
echo "=== Item 6: Increment on analyze round ==="

inc_line=$(grep -A1 'analyze_total_rounds++' "$SRC_DIR/autopilot.sh" || echo "")
assert_contains "$inc_line" "analyze_total_rounds++" "analyze_total_rounds incremented"

# ─── Item 7: Emission on force-advance blocks ────────────────────────────────

echo ""
echo "=== Item 7: Emission in force-advance blocks ==="

analyze_force=$(grep -A2 'force-advance analyze after' "$SRC_DIR/autopilot.sh" | head -3)
assert_contains "$analyze_force" "_emit_analyze_summary" "analyze force-advance emits summary"

av_force=$(grep -A2 'force-advance analyze-verify after' "$SRC_DIR/autopilot.sh" | head -3)
assert_contains "$av_force" "_emit_analyze_summary" "analyze-verify force-advance emits summary"

# ─── Results ──────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
