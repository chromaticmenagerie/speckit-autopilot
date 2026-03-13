#!/usr/bin/env bash
# test-branch-scoped-skip.sh — Verify skip detection scans only branch-changed files
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
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected '$expected', got '$actual'"
    fi
}

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

log() { :; }

source "$SRC_DIR/autopilot-verify.sh"

echo "=== Branch-scoped skip detection tests ==="

# Set up git repo with pre-existing skip on main, new clean test on feature branch
repo="$TMPDIR_ROOT/repo1"
mkdir -p "$repo"
(cd "$repo" && git init -q && git checkout -q -b main)

# Pre-existing skip on main (should NOT be flagged in branch mode)
cat > "$repo/handler.test.ts" <<'EOF'
describe('handler', () => {
  it.skip('legacy skip', () => {
    expect(true).toBe(true);
  });
});
EOF
(cd "$repo" && git add handler.test.ts && git commit -q -m "add legacy skip")

# Feature branch with clean new test
(cd "$repo" && git checkout -q -b feature)
cat > "$repo/new.test.ts" <<'EOF'
describe('new feature', () => {
  it('works', () => {
    expect(true).toBe(true);
  });
});
EOF
(cd "$repo" && git add new.test.ts && git commit -q -m "add new test")

# Test 1: Branch-scoped → only new.test.ts checked → no skip found
echo "Test 1: Pre-existing skip not flagged in branch mode"
PROJECT_LANG="Node/JS/TS"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
MERGE_TARGET="main"
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "error" || rc=$?
assert_eq "0" "$rc" "branch-scoped: pre-existing skip not flagged"

# Test 2: Add skip on feature branch → flagged
echo "Test 2: New skip on feature branch IS flagged"
cat > "$repo/another.test.ts" <<'EOF'
describe('another', () => {
  it.skip('new skip', () => {
    expect(true).toBe(true);
  });
});
EOF
(cd "$repo" && git add another.test.ts && git commit -q -m "add skip on branch")

rc=0
verify_tests "$repo" "error" || rc=$?
assert_eq "1" "$rc" "branch-scoped: new skip on branch IS flagged"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
