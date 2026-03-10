#!/usr/bin/env bash
# test-merge.sh — Unit tests for _pr_body() and _post_merge_cleanup()
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
        echo "  ✗ $msg: expected to contain '$needle', got '$haystack'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stubs
log() { :; }
_emit_event() { :; }

# Extract functions under test
eval "$(sed -n '/^_pr_body()/,/^}/p' "$SRC_DIR/autopilot-merge.sh")"
eval "$(sed -n '/^_post_merge_cleanup()/,/^}/p' "$SRC_DIR/autopilot-merge.sh")"
eval "$(sed -n '/^mark_epic_merged()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")"

# ─── Helper: setup_test_repo ────────────────────────────────────────────────

MERGE_TARGET="main"
LAST_TEST_REPO=""

setup_test_repo() {
    local base="$TMPDIR/test-$$-$RANDOM"
    local remote="$base/remote.git"
    local work="$base/work"

    # Create bare remote with an initial commit so clone isn't empty
    git init --bare -q "$remote"
    git clone -q "$remote" "$work" 2>/dev/null

    # Initial commit on main
    git -C "$work" checkout -b main 2>/dev/null || true
    echo "init" > "$work/README.md"
    git -C "$work" add README.md
    git -C "$work" commit -q -m "initial commit"
    git -C "$work" push -q -u origin main 2>/dev/null

    # Feature branch with a commit
    git -C "$work" checkout -q -b epic-042-feature
    echo "feature" > "$work/feature.txt"
    git -C "$work" add feature.txt
    git -C "$work" commit -q -m "feat(042): add feature"

    LAST_TEST_REPO="$work"
}

# ─── _pr_body tests ─────────────────────────────────────────────────────────

echo "=== _pr_body ==="

# Test 1: basic output contains epic header
setup_test_repo
output="$(_pr_body "$LAST_TEST_REPO" "042" "Test Feature" "epic-042-feature")"
assert_contains "$output" "## Epic" "basic output contains epic header"

# Test 2: contains changes section
assert_contains "$output" "### Changes" "contains changes section"

# Test 3: task count with 3 [x] items
setup_test_repo
mkdir -p "$LAST_TEST_REPO/specs/epic-042-feature"
cat > "$LAST_TEST_REPO/specs/epic-042-feature/tasks.md" <<'EOF'
- [x] Task one
- [x] Task two
- [x] Task three
- [ ] Task four
EOF
output="$(_pr_body "$LAST_TEST_REPO" "042" "Test Feature" "epic-042-feature")"
assert_contains "$output" "3 tasks" "task count with 3 [x] items"

# Test 4: no tasks.md
setup_test_repo
output="$(_pr_body "$LAST_TEST_REPO" "042" "Test Feature" "epic-042-feature")"
assert_contains "$output" "unknown" "no tasks.md shows unknown"

# Test 5: PROJECT_TEST_CMD set
setup_test_repo
PROJECT_TEST_CMD="echo ok"
output="$(_pr_body "$LAST_TEST_REPO" "042" "Test Feature" "epic-042-feature")"
assert_contains "$output" "Tests verified" "PROJECT_TEST_CMD set shows tests verified"

# Test 6: PROJECT_TEST_CMD unset
setup_test_repo
PROJECT_TEST_CMD=""
output="$(_pr_body "$LAST_TEST_REPO" "042" "Test Feature" "epic-042-feature")"
assert_contains "$output" "No test command" "PROJECT_TEST_CMD unset shows no test command"

# ─── _post_merge_cleanup tests ──────────────────────────────────────────────

echo "=== _post_merge_cleanup ==="

# Test 1: happy path — ends up on main branch
setup_test_repo
repo="$LAST_TEST_REPO"
epic_file="$repo/docs/specs/epics/epic-042-feature.md"
mkdir -p "$(dirname "$epic_file")"
cat > "$epic_file" <<'EOF'
---
epic_id: epic-042
status: in_progress
branch: epic-042-feature
---
# Epic: Test Feature
EOF
_post_merge_cleanup "$repo" "042" "epic-042-feature" "$epic_file" >/dev/null 2>&1
branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
assert_eq "main" "$branch" "happy path: on main branch after cleanup"

# Test 2: happy path — epic file has status: merged
grep_result="$(grep 'status: merged' "$epic_file" || echo "")"
assert_contains "$grep_result" "status: merged" "happy path: epic file has status merged"

# Test 3: happy path — commit exists on main mentioning the epic
commit_log="$(git -C "$repo" log --oneline main)"
assert_contains "$commit_log" "042" "happy path: commit on main mentions epic"

# Test 4: no epic file arg — pass empty string, no crash
setup_test_repo
rc=0
_post_merge_cleanup "$LAST_TEST_REPO" "042" "epic-042-feature" "" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "no epic file arg: returns 0"

# Test 5: nonexistent epic file — pass fake path, no crash
setup_test_repo
rc=0
_post_merge_cleanup "$LAST_TEST_REPO" "042" "epic-042-feature" "/tmp/nonexistent-epic-file.md" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" "nonexistent epic file: returns 0"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
