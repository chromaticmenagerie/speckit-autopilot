#!/usr/bin/env bash
# test-phase-log-append.sh — Tests that phase logs APPEND with round separators
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

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: '$haystack' should NOT contain '$needle'"
    fi
}

assert_line_count_ge() {
    local file="$1" min="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    local count
    count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
    if [[ "$count" -ge "$min" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected >= $min lines, got $count"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

log() { :; }
BOLD="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM=""
declare -A PHASE_MODEL=([clarify]="test-model" [test-phase]="test-model")
SILENT=true
AUTOPILOT_LOG=""
AUTOPILOT_STATUS_FILE=""
REPO_ROOT="$TMPDIR_ROOT"

mkdir -p "$REPO_ROOT/.specify/logs"

source "$SRC_DIR/autopilot-stream.sh"

# ─── Unit test: _write_phase_log ─────────────────────────────────────────

echo "Case 1: _write_phase_log — first write has no separator"

test_log="$TMPDIR_ROOT/test1.log"
rm -f "$test_log"
_write_phase_log "$test_log" "First round output" "clarify"

content=$(cat "$test_log")
assert_contains "$content" "First round output" "first write contains content"
assert_not_contains "$content" "---" "first write has no separator"

# ─── Case 2: second write adds separator ─────────────────────────────────

echo ""
echo "Case 2: _write_phase_log — second write adds separator"

_write_phase_log "$test_log" "Second round output" "clarify"

content=$(cat "$test_log")
assert_contains "$content" "First round output" "preserves first round"
assert_contains "$content" "Second round output" "contains second round"
assert_contains "$content" "---" "separator present"
assert_contains "$content" "## clarify" "separator contains phase name"

# ─── Case 3: third write adds another separator ──────────────────────────

echo ""
echo "Case 3: _write_phase_log — third write adds another separator"

_write_phase_log "$test_log" "Third round output" "clarify"

content=$(cat "$test_log")
assert_contains "$content" "First round output" "preserves first round"
assert_contains "$content" "Second round output" "preserves second round"
assert_contains "$content" "Third round output" "contains third round"

# Count separators — should be exactly 2
sep_count=$(grep -c '^---$' "$test_log" || true)
# Each separator block has 2 --- lines, so expect 4
assert_eq "4" "$sep_count" "two separator blocks (4 --- lines)"

# ─── Case 4: Full process_stream appends on second run ───────────────────

echo ""
echo "Case 4: process_stream appends phase log on re-run"

FIXTURE_SUCCESS='{"type":"system","model":"test-model","session_id":"test-s1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Run one output."}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0}}}
{"type":"result","duration_ms":5000,"total_cost_usd":0.01,"result":"Run one output.","subtype":"success","is_error":false}'

rm -f "$REPO_ROOT/.specify/logs/events.jsonl" "$REPO_ROOT/.specify/logs/001-test-phase.log"

echo "$FIXTURE_SUCCESS" | (process_stream "001" "test-phase") 2>/dev/null || true

FIXTURE_SUCCESS2='{"type":"system","model":"test-model","session_id":"test-s2"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Run two output."}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0}}}
{"type":"result","duration_ms":3000,"total_cost_usd":0.005,"result":"Run two output.","subtype":"success","is_error":false}'

echo "$FIXTURE_SUCCESS2" | (process_stream "001" "test-phase") 2>/dev/null || true

phase_log="$REPO_ROOT/.specify/logs/001-test-phase.log"
content=$(cat "$phase_log")

assert_contains "$content" "Run one output." "first run preserved"
assert_contains "$content" "Run two output." "second run appended"
assert_contains "$content" "---" "separator between runs"
assert_contains "$content" "## test-phase" "separator has phase name"

# ─── Case 5: error subtypes also append ──────────────────────────────────

echo ""
echo "Case 5: error_max_turns also appends (not overwrite)"

FIXTURE_ERROR='{"type":"system","model":"test-model","session_id":"test-e1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Error round output."}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":0}}}
{"type":"result","duration_ms":60000,"total_cost_usd":0.10,"result":"","subtype":"error_max_turns","is_error":true}'

# Don't clean log — append to existing
echo "$FIXTURE_ERROR" | (process_stream "001" "test-phase") 2>/dev/null || true

content=$(cat "$phase_log")
assert_contains "$content" "Run one output." "still has first run"
assert_contains "$content" "Run two output." "still has second run"
assert_contains "$content" "Error round output." "error output appended"

# ─── Case 6: empty file gets no separator ────────────────────────────────

echo ""
echo "Case 6: writing to empty file produces no separator"

empty_log="$TMPDIR_ROOT/empty.log"
touch "$empty_log"  # exists but empty
_write_phase_log "$empty_log" "Content after empty" "clarify"

content=$(cat "$empty_log")
assert_contains "$content" "Content after empty" "content written"
assert_not_contains "$content" "---" "no separator for empty file"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
