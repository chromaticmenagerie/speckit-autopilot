#!/usr/bin/env bash
# test-detect-state.sh — Verify detect_state() returns clean values (no log contamination)
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

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Source the library (log() now writes to stderr, so it won't contaminate stdout)
AUTOPILOT_LOG=""
BASE_BRANCH="master"
source "$SRC_DIR/autopilot-lib.sh"

# Stub find_pen_file and is_epic_merged (not relevant for these tests)
find_pen_file() { echo ""; }
is_epic_merged() { return 1; }

# ─── Test: prefix mismatch returns clean "specify" ──────────────────────────

echo "Test: prefix mismatch returns clean 'specify' on stdout"

repo="$TMPDIR/repo-mismatch"
mkdir -p "$repo/specs/001-wrong-name"
echo "# spec" > "$repo/specs/001-wrong-name/spec.md"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

state=$(detect_state "$repo" "003" "001-wrong-name" 2>/dev/null)
assert_eq "specify" "$state" "stdout is exactly 'specify'"

# ─── Test: prefix mismatch logs warning to stderr ───────────────────────────

echo "Test: prefix mismatch logs warning to stderr"

state=$(detect_state "$repo" "003" "001-wrong-name" 2>"$TMPDIR/stderr")
stderr_output=$(cat "$TMPDIR/stderr")
assert_eq "specify" "$state" "stdout still clean 'specify'"
assert_contains "$stderr_output" "doesn't match" "stderr contains warning about mismatch"

# ─── Test: matching prefix returns correct state ────────────────────────────

echo "Test: matching prefix returns correct state (not 'specify')"

repo2="$TMPDIR/repo-match"
mkdir -p "$repo2/specs/003-my-feature"
echo "# spec" > "$repo2/specs/003-my-feature/spec.md"
git -C "$repo2" init -q
git -C "$repo2" commit --allow-empty -m "init" -q

state=$(detect_state "$repo2" "003" "003-my-feature" 2>/dev/null)
# Should advance past specify since spec.md exists — expect "clarify"
assert_eq "clarify" "$state" "correct prefix advances past specify"

# ─── Test: empty short_name returns "specify" ───────────────────────────────

echo "Test: empty short_name returns 'specify'"

state=$(detect_state "$repo2" "003" "" 2>/dev/null)
assert_eq "specify" "$state" "empty short_name returns specify"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
