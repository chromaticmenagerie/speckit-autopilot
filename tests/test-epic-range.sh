#!/usr/bin/env bash
# test-epic-range.sh — Unit tests for dash-range epic targeting (e.g., 003-007)
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

assert_empty() {
    local actual="$1" msg="${2:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -z "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected empty, got '$actual'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Minimal stubs so autopilot-lib.sh can source without errors
AUTOPILOT_LOG=""
log() { :; }

source "$SRC_DIR/common.sh"

# Extract functions we need from autopilot-lib.sh
eval "$(sed -n '/^list_epics()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")"
eval "$(sed -n '/^is_epic_merged()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")"
eval "$(sed -n '/^find_next_epic()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")"

# Extract parse_args and related globals from autopilot.sh
# We source just the argument-parsing logic
TARGET_EPIC=""
TARGET_EPICS=()

# Extract parse_args function
eval "$(sed -n '/^parse_args()/,/^}/p' "$SRC_DIR/autopilot.sh")"

# Stub PHASE_MAX_RETRIES (needed by parse_args)
declare -A PHASE_MAX_RETRIES=()

# ─── Helper: create mock epic file ──────────────────────────────────────────

create_mock_epic() {
    local repo_root="$1" num="$2" name="$3" status="${4:-draft}"
    local epics_dir="$repo_root/docs/specs/epics"
    mkdir -p "$epics_dir"
    cat > "$epics_dir/epic-${num}.md" << EOF
---
epic_id: epic-${num}
status: ${status}
branch: ${num}-${name}
---
# Epic: ${name}
EOF
}

# ─── Range Parsing Tests ────────────────────────────────────────────────────

echo "=== Range Parsing Tests ==="

# Test 1: Valid range 003-007
echo "Test 1: Valid range 003-007 expands correctly"

TARGET_EPIC=""
TARGET_EPICS=()
parse_args "003-007"
assert_eq "5" "${#TARGET_EPICS[@]}" "range 003-007 produces 5 elements"
assert_eq "003" "${TARGET_EPICS[0]}" "first element is 003"
assert_eq "004" "${TARGET_EPICS[1]}" "second element is 004"
assert_eq "005" "${TARGET_EPICS[2]}" "third element is 005"
assert_eq "006" "${TARGET_EPICS[3]}" "fourth element is 006"
assert_eq "007" "${TARGET_EPICS[4]}" "fifth element is 007"

# Test 2: Single-element range 003-003
echo "Test 2: Single-element range 003-003"

TARGET_EPIC=""
TARGET_EPICS=()
parse_args "003-003"
assert_eq "1" "${#TARGET_EPICS[@]}" "range 003-003 produces 1 element"
assert_eq "003" "${TARGET_EPICS[0]}" "single element is 003"

# Test 3: Invalid range 007-003 (min > max) should error
echo "Test 3: Invalid range 007-003 errors"

TARGET_EPIC=""
TARGET_EPICS=()
error_output="$(parse_args "007-003" 2>&1)" && exit_code=0 || exit_code=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [[ $exit_code -ne 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ invalid range 007-003 exits with non-zero"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ invalid range 007-003 should exit non-zero, got 0"
fi

# Test 4: Leading zeros preserved
echo "Test 4: Leading zeros preserved in range 003-012"

TARGET_EPIC=""
TARGET_EPICS=()
parse_args "003-012"
assert_eq "10" "${#TARGET_EPICS[@]}" "range 003-012 produces 10 elements"
assert_eq "003" "${TARGET_EPICS[0]}" "first element preserves leading zero: 003"
assert_eq "009" "${TARGET_EPICS[6]}" "007th element preserves leading zero: 009"
assert_eq "010" "${TARGET_EPICS[7]}" "008th element preserves leading zero: 010"
assert_eq "012" "${TARGET_EPICS[9]}" "last element preserves leading zero: 012"

# ─── find_next_epic Range Filtering Tests ────────────────────────────────────

echo ""
echo "=== find_next_epic Range Filtering Tests ==="

# Test 5: Range filters correctly — only returns epics within range
echo "Test 5: Range filters correctly"

repo="$TMPDIR/repo-range-filter"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

create_mock_epic "$repo" "001" "alpha"
create_mock_epic "$repo" "002" "bravo"
create_mock_epic "$repo" "003" "charlie"
create_mock_epic "$repo" "004" "delta"
create_mock_epic "$repo" "005" "echo-feat"

BASE_BRANCH="$(git -C "$repo" branch --show-current)"
MERGE_TARGET="$BASE_BRANCH"

# find_next_epic with no target returns first unmerged
result="$(find_next_epic "$repo" "")"
first_num="${result%%|*}"
assert_eq "001" "$first_num" "no target returns first epic (001)"

# With specific target, returns that epic
result="$(find_next_epic "$repo" "003")"
first_num="${result%%|*}"
assert_eq "003" "$first_num" "target 003 returns epic 003"

# Test 6: Skips merged epics in range
echo "Test 6: Skips merged epics in range"

repo="$TMPDIR/repo-skip-merged"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

create_mock_epic "$repo" "003" "charlie" "merged"
create_mock_epic "$repo" "004" "delta" "draft"
create_mock_epic "$repo" "005" "echo-feat" "merged"

BASE_BRANCH="$(git -C "$repo" branch --show-current)"
MERGE_TARGET="$BASE_BRANCH"

# Without target, find_next_epic skips merged and returns 004
result="$(find_next_epic "$repo" "")"
first_num="${result%%|*}"
assert_eq "004" "$first_num" "skips merged 003, returns 004"

# Test 7: Empty range (all merged) — returns empty
echo "Test 7: All epics merged returns empty"

repo="$TMPDIR/repo-all-merged"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

create_mock_epic "$repo" "003" "charlie" "merged"
create_mock_epic "$repo" "004" "delta" "merged"
create_mock_epic "$repo" "005" "echo-feat" "merged"

BASE_BRANCH="$(git -C "$repo" branch --show-current)"
MERGE_TARGET="$BASE_BRANCH"

result="$(find_next_epic "$repo" "")"
assert_empty "$result" "all merged returns empty"

# Test 8: Gap in range (missing epic) — skips gracefully
echo "Test 8: Gap in range (missing epic 004) skips gracefully"

repo="$TMPDIR/repo-gap"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

create_mock_epic "$repo" "003" "charlie" "merged"
# No epic 004
create_mock_epic "$repo" "005" "echo-feat" "draft"

BASE_BRANCH="$(git -C "$repo" branch --show-current)"
MERGE_TARGET="$BASE_BRANCH"

# find_next_epic with no target skips merged 003, skips missing 004, returns 005
result="$(find_next_epic "$repo" "")"
first_num="${result%%|*}"
assert_eq "005" "$first_num" "skips merged 003 and missing 004, returns 005"

# ─── Backward Compatibility Tests ───────────────────────────────────────────

echo ""
echo "=== Backward Compatibility Tests ==="

# Test 9: Single epic still works — TARGET_EPIC="003" with empty TARGET_EPICS
echo "Test 9: Single epic argument still works"

TARGET_EPIC=""
TARGET_EPICS=()
parse_args "003"
assert_eq "003" "$TARGET_EPIC" "single arg sets TARGET_EPIC"
assert_eq "0" "${#TARGET_EPICS[@]}" "single arg leaves TARGET_EPICS empty"

# Test 10: No argument still works — empty TARGET_EPIC and empty TARGET_EPICS
echo "Test 10: No argument leaves both empty"

TARGET_EPIC=""
TARGET_EPICS=()
parse_args
assert_eq "" "$TARGET_EPIC" "no arg leaves TARGET_EPIC empty"
assert_eq "0" "${#TARGET_EPICS[@]}" "no arg leaves TARGET_EPICS empty"

# Verify find_next_epic with no target returns first unmerged
repo="$TMPDIR/repo-no-arg"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

create_mock_epic "$repo" "001" "alpha" "merged"
create_mock_epic "$repo" "002" "bravo" "draft"
create_mock_epic "$repo" "003" "charlie" "draft"

BASE_BRANCH="$(git -C "$repo" branch --show-current)"
MERGE_TARGET="$BASE_BRANCH"

result="$(find_next_epic "$repo" "")"
first_num="${result%%|*}"
assert_eq "002" "$first_num" "no target returns first unmerged epic (002)"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
