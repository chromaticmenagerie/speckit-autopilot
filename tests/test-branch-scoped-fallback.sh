#!/usr/bin/env bash
# test-branch-scoped-fallback.sh — Verify fallback to full-repo scan when git unavailable
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

echo "=== Branch-scoped fallback tests ==="

# Non-git directory with a skip → full-repo scan catches it
repo="$TMPDIR_ROOT/non-git"
mkdir -p "$repo"
cat > "$repo/handler.test.ts" <<'EOF'
describe('handler', () => {
  it.skip('should work', () => {
    expect(true).toBe(true);
  });
});
EOF

echo "Test 1: Non-git dir → falls back to full-repo scan"
PROJECT_LANG="Node/JS/TS"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
MERGE_TARGET="main"
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "error" || rc=$?
assert_eq "1" "$rc" "fallback: skip detected in non-git dir"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
