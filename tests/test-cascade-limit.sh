#!/usr/bin/env bash
# test-cascade-limit.sh — Unit tests for cascade circuit breaker
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
        echo "  ✗ $msg: '$needle' not found in output"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

LOG_OUTPUT=""
log() { LOG_OUTPUT+="[$1] ${*:2}"$'\n'; }

# Stub git so _check_cascade_limit doesn't fail on git calls
git() { :; }

# Extract _check_cascade_limit from autopilot.sh
eval "$(sed -n '/_check_cascade_limit()/,/^}/p' "$SRC_DIR/autopilot.sh")"

# Extract parse_args for --allow-cascade test
declare -A PHASE_MAX_RETRIES=()
TARGET_EPIC=""
TARGET_EPICS=()
AUTO_CONTINUE=true
DRY_RUN=false
SILENT=false
NO_GITHUB=false
GITHUB_RESYNC=false
STRICT_DEPS=false
ALLOW_DEFERRED=false
SKIP_CODERABBIT=false
SKIP_REVIEW=false
SECURITY_FORCE_SKIP_ALLOWED=false
REQUIREMENTS_FORCE_SKIP_ALLOWED=false
FORCE_SKIP_CASCADE_LIMIT=3
MAX_ITERATIONS=""
eval "$(sed -n '/^parse_args()/,/^}/p' "$SRC_DIR/autopilot.sh")"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== Cascade Circuit Breaker Tests ==="

# Test 1: 1 force-skip → WARN logged, returns 0
echo "Test 1: single force-skip warns and continues"
force_skip_count=0
FORCE_SKIP_CASCADE_LIMIT=3
LOG_OUTPUT=""
tasks_file="$TMPDIR_TEST/tasks1.md"
echo "# Tasks" > "$tasks_file"
rc=0; _check_cascade_limit "$TMPDIR_TEST" "001" "$tasks_file" || rc=$?
assert_eq "0" "$rc" "returns 0"
assert_eq "1" "$force_skip_count" "force_skip_count incremented to 1"
assert_contains "$LOG_OUTPUT" "1 gate(s) force-skipped" "WARN logged"

# Test 2: 2 force-skips (limit-1 when limit=3) → CASCADE WARNING
echo "Test 2: limit-1 force-skips → CASCADE WARNING"
force_skip_count=1
FORCE_SKIP_CASCADE_LIMIT=3
LOG_OUTPUT=""
tasks_file="$TMPDIR_TEST/tasks2.md"
echo "# Tasks" > "$tasks_file"
rc=0; _check_cascade_limit "$TMPDIR_TEST" "001" "$tasks_file" || rc=$?
assert_eq "0" "$rc" "returns 0"
assert_eq "2" "$force_skip_count" "force_skip_count incremented to 2"
assert_contains "$LOG_OUTPUT" "CASCADE WARNING" "CASCADE WARNING logged"

# Test 3: 3 force-skips (limit=3) → CASCADE LIMIT REACHED, return 1, marker
echo "Test 3: limit reached → halt + marker"
force_skip_count=2
FORCE_SKIP_CASCADE_LIMIT=3
LOG_OUTPUT=""
tasks_file="$TMPDIR_TEST/tasks3.md"
echo "# Tasks" > "$tasks_file"
rc=0; _check_cascade_limit "$TMPDIR_TEST" "001" "$tasks_file" || rc=$?
assert_eq "1" "$rc" "returns 1"
assert_eq "3" "$force_skip_count" "force_skip_count incremented to 3"
assert_contains "$LOG_OUTPUT" "CASCADE LIMIT REACHED" "CASCADE LIMIT REACHED logged"
marker=$(grep -c 'CASCADE_LIMIT_REACHED' "$tasks_file" 2>/dev/null) || marker=0
assert_eq "1" "$marker" "marker written to tasks file"

# Test 4: --allow-cascade sets FORCE_SKIP_CASCADE_LIMIT=99
echo "Test 4: --allow-cascade sets limit to 99"
FORCE_SKIP_CASCADE_LIMIT=3
parse_args --allow-cascade
assert_eq "99" "$FORCE_SKIP_CASCADE_LIMIT" "--allow-cascade → limit=99"

# Test 5: FORCE_SKIP_CASCADE_LIMIT=0 → first force-skip halts (strict mode)
echo "Test 5: limit=0 → first skip halts"
force_skip_count=0
FORCE_SKIP_CASCADE_LIMIT=0
LOG_OUTPUT=""
tasks_file="$TMPDIR_TEST/tasks5.md"
echo "# Tasks" > "$tasks_file"
rc=0; _check_cascade_limit "$TMPDIR_TEST" "002" "$tasks_file" || rc=$?
assert_eq "1" "$rc" "returns 1 on first skip"
assert_eq "1" "$force_skip_count" "force_skip_count is 1"
assert_contains "$LOG_OUTPUT" "CASCADE LIMIT REACHED" "strict mode halts immediately"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
