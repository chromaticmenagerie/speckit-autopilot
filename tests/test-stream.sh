#!/usr/bin/env bash
# test-stream.sh — Tests for autopilot-stream.sh NDJSON processor
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

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Stubs — must be defined before sourcing autopilot-stream.sh
log() { :; }
BOLD="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM=""
declare -A PHASE_MODEL=([test-phase]="test-model")
SILENT=true
AUTOPILOT_LOG=""
AUTOPILOT_STATUS_FILE=""
REPO_ROOT="$TMPDIR_ROOT"

mkdir -p "$REPO_ROOT/.specify/logs"

# Source the stream processor
source "$SRC_DIR/autopilot-stream.sh"

# ─── Case 1: Success with text result ───────────────────────────────────────

echo "Case 1: Success with text result"

FIXTURE_1='{"type":"system","model":"test-model","session_id":"test-1"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Review complete. All good."}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0}}}
{"type":"result","duration_ms":5000,"total_cost_usd":0.01,"result":"Review complete. All good.","subtype":"success","is_error":false}'

# Clean logs for this case
rm -f "$REPO_ROOT/.specify/logs/events.jsonl" "$REPO_ROOT/.specify/logs/001-test-phase.log"

exit_code=0
echo "$FIXTURE_1" | (process_stream "001" "test-phase") 2>/dev/null || exit_code=$?

assert_eq "0" "$exit_code" "exit code is 0"

phase_log_content=$(cat "$REPO_ROOT/.specify/logs/001-test-phase.log" 2>/dev/null || echo "")
assert_contains "$phase_log_content" "Review complete. All good." "phase_log contains result text"

events_content=$(cat "$REPO_ROOT/.specify/logs/events.jsonl" 2>/dev/null || echo "")
assert_not_contains "$events_content" "phase_warning" "no phase_warning event emitted"

# ─── Case 2: Empty .result with text+tool_use in last assistant ─────────────

echo ""
echo "Case 2: Empty .result — fallback from last assistant text"

FIXTURE_2='{"type":"system","model":"test-model","session_id":"test-2"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Committing review fixes now."},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"git commit -m fix"}}],"stop_reason":"tool_use","usage":{"input_tokens":200,"output_tokens":80,"cache_read_input_tokens":0}}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"committed","is_error":false}]}}
{"type":"result","duration_ms":8000,"total_cost_usd":0.02,"result":"","subtype":"success","is_error":false}'

rm -f "$REPO_ROOT/.specify/logs/events.jsonl" "$REPO_ROOT/.specify/logs/001-test-phase.log"

exit_code=0
echo "$FIXTURE_2" | (process_stream "001" "test-phase") 2>/dev/null || exit_code=$?

assert_eq "0" "$exit_code" "exit code is 0"

phase_log_content=$(cat "$REPO_ROOT/.specify/logs/001-test-phase.log" 2>/dev/null || echo "")
assert_contains "$phase_log_content" "Committing review fixes now." "phase_log contains fallback text"

events_content=$(cat "$REPO_ROOT/.specify/logs/events.jsonl" 2>/dev/null || echo "")
assert_contains "$events_content" "phase_warning" "phase_warning event emitted"

# ─── Case 2b: Empty .result, last assistant is pure tool_use ────────────────

echo ""
echo "Case 2b: Empty .result — last assistant is pure tool_use (no text)"

FIXTURE_2B='{"type":"system","model":"test-model","session_id":"test-2b"}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"git commit -m fix"}}],"stop_reason":"tool_use","usage":{"input_tokens":200,"output_tokens":50,"cache_read_input_tokens":0}}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"committed","is_error":false}]}}
{"type":"result","duration_ms":8000,"total_cost_usd":0.02,"result":"","subtype":"success","is_error":false}'

rm -f "$REPO_ROOT/.specify/logs/events.jsonl" "$REPO_ROOT/.specify/logs/001-test-phase.log"

exit_code=0
stderr_output=""
stderr_output=$(echo "$FIXTURE_2B" | (process_stream "001" "test-phase") 2>&1 >/dev/null) || exit_code=$?
# Also capture exit code properly — process_stream runs in same shell via pipe
exit_code=0
rm -f "$REPO_ROOT/.specify/logs/events.jsonl" "$REPO_ROOT/.specify/logs/001-test-phase.log"
echo "$FIXTURE_2B" | (process_stream "001" "test-phase") 2>/dev/null || exit_code=$?

assert_eq "0" "$exit_code" "exit code is 0"

phase_log_content=$(cat "$REPO_ROOT/.specify/logs/001-test-phase.log" 2>/dev/null || echo "")
# Phase log should be empty/whitespace — both .result and _last_assistant_text are empty
trimmed="${phase_log_content// /}"
trimmed="${trimmed//$'\n'/}"
assert_eq "" "$trimmed" "phase_log is empty (no fallback text available)"

# ─── Case 3: error_max_turns with fallback text ────────────────────────────

echo ""
echo "Case 3: error_max_turns — fallback text preserved, exit 3"

FIXTURE_3='{"type":"system","model":"test-model","session_id":"test-3"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Partial progress: reviewed 5 files."}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":0}}}
{"type":"result","duration_ms":60000,"total_cost_usd":0.10,"result":"","subtype":"error_max_turns","is_error":true}'

rm -f "$REPO_ROOT/.specify/logs/events.jsonl" "$REPO_ROOT/.specify/logs/001-test-phase.log"

exit_code=0
echo "$FIXTURE_3" | (process_stream "001" "test-phase") 2>/dev/null || exit_code=$?

assert_eq "3" "$exit_code" "exit code is 3 (error_max_turns)"

phase_log_content=$(cat "$REPO_ROOT/.specify/logs/001-test-phase.log" 2>/dev/null || echo "")
assert_contains "$phase_log_content" "Partial progress: reviewed 5 files." "phase_log contains fallback text"

# ─── Case 4: Rate limit detection ──────────────────────────────────────────

echo ""
echo "Case 4: Rate limit — exit 42"

FIXTURE_4='{"type":"system","model":"test-model","session_id":"test-4"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Working..."}],"stop_reason":"rate_limit","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":0}}}
{"type":"result","duration_ms":1000,"total_cost_usd":0.001,"result":"","subtype":"unknown","is_error":false}'

rm -f "$REPO_ROOT/.specify/logs/events.jsonl" "$REPO_ROOT/.specify/logs/001-test-phase.log"

exit_code=0
echo "$FIXTURE_4" | (process_stream "001" "test-phase") 2>/dev/null || exit_code=$?

assert_eq "42" "$exit_code" "exit code is 42 (rate limit)"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
