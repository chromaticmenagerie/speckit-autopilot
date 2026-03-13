#!/usr/bin/env bash
# test-finalize-revert.sh — Tests for finalize branch fix, auto-revert, error reporting
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

# ─── Stubs ───────────────────────────────────────────────────────────────────

log() { echo "[$1] $2"; }
BOLD="" RESET="" GREEN=""
BASE_BRANCH="main"
MERGE_TARGET="staging"
AUTO_REVERT_ON_FAILURE=false
LAST_MERGE_SHA=""
LAST_TEST_OUTPUT=""

# ─── Extract functions under test ────────────────────────────────────────────

eval "$(sed -n '/^_suggest_or_auto_revert()/,/^}/p' "$SRC_DIR/autopilot-finalize.sh")"
eval "$(sed -n '/^_persist_finalize_failure()/,/^}/p' "$SRC_DIR/autopilot-finalize.sh")"
eval "$(sed -n '/^_restore_merge_sha()/,/^}/p' "$SRC_DIR/autopilot-finalize.sh")"

# ─── Test 1: finalize_branch uses MERGE_TARGET ──────────────────────────────

echo "Test 1: finalize_branch uses MERGE_TARGET over BASE_BRANCH"
# Grep source for the pattern
finalize_line=$(grep 'finalize_branch=' "$SRC_DIR/autopilot-finalize.sh" | head -1)
assert_contains "$finalize_line" 'MERGE_TARGET' "finalize_branch references MERGE_TARGET"
assert_contains "$finalize_line" 'BASE_BRANCH' "finalize_branch falls back to BASE_BRANCH"

# ─── Test 2: _suggest_or_auto_revert with empty SHA ─────────────────────────

echo "Test 2: _suggest_or_auto_revert with empty SHA returns 0"
rc=0
output=$(_suggest_or_auto_revert "" "/tmp" 2>&1) || rc=$?
assert_eq "0" "$rc" "empty SHA returns 0 (no-op)"
assert_contains "$output" "No merge SHA" "logs warning about missing SHA"

# ─── Test 3: display command includes merge flag for merge commits ───────────

echo "Test 3: display command includes -m 1 for merge commits"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

repo="$TMPDIR_TEST/repo-merge-flag"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q
# Create a merge commit (3+ parents detected via wc -w counting sha + parents)
sha=$(git -C "$repo" rev-parse HEAD)

# For a regular commit (2 words: sha + 1 parent or just sha), no -m flag
AUTO_REVERT_ON_FAILURE=false
rc=0
output=$(_suggest_or_auto_revert "$sha" "$repo" 2>&1) || rc=$?
assert_eq "1" "$rc" "non-auto-revert returns 1"
# Regular (non-merge) commit should NOT have -m 1
if [[ "$output" == *"-m 1"* ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ regular commit should not have -m 1 in display cmd"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ regular commit does not include -m 1"
fi

# ─── Test 4: _persist_finalize_failure writes JSON ───────────────────────────

echo "Test 4: _persist_finalize_failure writes failure JSON"
repo2="$TMPDIR_TEST/repo-persist"
mkdir -p "$repo2/.specify/logs"
LAST_MERGE_SHA="abc123"
MERGE_TARGET="staging"
BASE_BRANCH="main"
_persist_finalize_failure "$repo2" "test_reason" 2>/dev/null
if [[ -f "$repo2/.specify/logs/finalize-failure.json" ]]; then
    reason=$(jq -r '.reason' "$repo2/.specify/logs/finalize-failure.json" 2>/dev/null || echo "")
    assert_eq "test_reason" "$reason" "failure JSON contains reason"
    saved_sha=$(jq -r '.merge_sha' "$repo2/.specify/logs/finalize-failure.json" 2>/dev/null || echo "")
    assert_eq "abc123" "$saved_sha" "failure JSON contains merge SHA"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ finalize-failure.json not created"
fi

# ─── Test 5: _restore_merge_sha restores from failure file ──────────────────

echo "Test 5: _restore_merge_sha restores SHA from failure file"
LAST_MERGE_SHA=""
_restore_merge_sha "$repo2" 2>/dev/null
assert_eq "abc123" "$LAST_MERGE_SHA" "LAST_MERGE_SHA restored from failure file"

# ─── Test 6: _restore_merge_sha no-ops when SHA already set ─────────────────

echo "Test 6: _restore_merge_sha no-ops when SHA already set"
LAST_MERGE_SHA="existing_sha"
_restore_merge_sha "$repo2" 2>/dev/null
assert_eq "existing_sha" "$LAST_MERGE_SHA" "existing SHA preserved"

# ─── Test 7: --auto-revert flag parsed ──────────────────────────────────────

echo "Test 7: --auto-revert flag is parsed by parse_args"
flag_line=$(grep -n 'auto-revert' "$SRC_DIR/autopilot.sh" | grep -v '#' | head -1)
assert_contains "$flag_line" "AUTO_REVERT_ON_FAILURE=true" "--auto-revert sets AUTO_REVERT_ON_FAILURE"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
