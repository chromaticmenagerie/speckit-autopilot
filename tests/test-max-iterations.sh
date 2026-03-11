#!/usr/bin/env bash
# test-max-iterations.sh — Unit tests for --max-iterations argument parsing
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

log() { :; }
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
MAX_ITERATIONS=""

eval "$(sed -n '/^parse_args()/,/^}/p' "$SRC_DIR/autopilot.sh")"

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== --max-iterations Tests ==="

# Test 1: --max-iterations 50
echo "Test 1: --max-iterations 50 sets value"
MAX_ITERATIONS=""
parse_args --max-iterations 50
assert_eq "50" "$MAX_ITERATIONS" "--max-iterations 50"

# Test 2: no flag — empty
echo "Test 2: no flag leaves MAX_ITERATIONS empty"
MAX_ITERATIONS=""
parse_args
assert_eq "" "$MAX_ITERATIONS" "default is empty"

# Test 3: --max-iterations 0 exits non-zero (subshell — parse_args calls exit)
echo "Test 3: --max-iterations 0 rejects"
rc=0; (parse_args --max-iterations 0) 2>/dev/null || rc=$?
assert_eq "1" "$rc" "--max-iterations 0 exits non-zero"

# Test 4: --max-iterations -1 exits non-zero
echo "Test 4: --max-iterations -1 rejects"
rc=0; (parse_args --max-iterations -1) 2>/dev/null || rc=$?
assert_eq "1" "$rc" "--max-iterations -1 exits non-zero"

# Test 5: --max-iterations abc exits non-zero
echo "Test 5: --max-iterations abc rejects"
rc=0; (parse_args --max-iterations abc) 2>/dev/null || rc=$?
assert_eq "1" "$rc" "--max-iterations abc exits non-zero"

# Test 6: --max-iterations 5 sets value (warn is runtime)
echo "Test 6: --max-iterations 5 sets value"
MAX_ITERATIONS=""
parse_args --max-iterations 5
assert_eq "5" "$MAX_ITERATIONS" "--max-iterations 5"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
