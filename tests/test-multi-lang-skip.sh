#!/usr/bin/env bash
# test-multi-lang-skip.sh — Tests for multi-language stub/skip detection
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

assert_not_empty() {
    local actual="$1" msg="${2:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -n "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected non-empty, got empty"
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

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Stub log()
log() { :; }

# Source verify_tests by sourcing the whole file (awk inlines break eval+sed)
source "$SRC_DIR/autopilot-verify.sh"

# ─── Go Tests ───────────────────────────────────────────────────────────────

echo "=== Go stub detection ==="

# Test 1: Go unconditional t.Skip detected
echo "Test 1: Go unconditional t.Skip() detected"
repo="$TMPDIR_ROOT/go-skip"
mkdir -p "$repo"
cat > "$repo/handler_test.go" <<'EOF'
package main

import "testing"

func TestHandler(t *testing.T) {
	t.Skip("not implemented yet")
}
EOF
PROJECT_LANG="Go"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "error" || rc=$?
assert_eq "1" "$rc" "Go unconditional t.Skip returns error"

# Test 2: Go conditional t.Skip NOT detected (accuracy improvement)
echo "Test 2: Go conditional t.Skip() NOT detected"
repo2="$TMPDIR_ROOT/go-conditional"
mkdir -p "$repo2"
cat > "$repo2/handler_test.go" <<'EOF'
package main

import "testing"

func TestHandler(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping in short mode")
	}
	// real test logic
	if 1 != 1 {
		t.Fatal("math broken")
	}
}
EOF
PROJECT_LANG="Go"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo2" "error" || rc=$?
assert_eq "0" "$rc" "Go conditional t.Skip not flagged"

# Test 3: Go t.Skipf unconditional detected
echo "Test 3: Go unconditional t.Skipf() detected"
repo3="$TMPDIR_ROOT/go-skipf"
mkdir -p "$repo3"
cat > "$repo3/handler_test.go" <<'EOF'
package main

import "testing"

func TestHandler(t *testing.T) {
	t.Skipf("TODO: implement %s", "handler")
}
EOF
PROJECT_LANG="Go"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo3" "error" || rc=$?
assert_eq "1" "$rc" "Go unconditional t.Skipf returns error"

# Test 4: Go t.SkipNow unconditional detected
echo "Test 4: Go unconditional t.SkipNow() detected"
repo4="$TMPDIR_ROOT/go-skipnow"
mkdir -p "$repo4"
cat > "$repo4/handler_test.go" <<'EOF'
package main

import "testing"

func TestHandler(t *testing.T) {
	t.SkipNow()
}
EOF
PROJECT_LANG="Go"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo4" "error" || rc=$?
assert_eq "1" "$rc" "Go unconditional t.SkipNow returns error"

# ─── Python Tests ───────────────────────────────────────────────────────────

echo ""
echo "=== Python stub detection ==="

# Test 5: Python unconditional @pytest.mark.skip detected
echo "Test 5: Python @pytest.mark.skip detected"
repo5="$TMPDIR_ROOT/py-skip"
mkdir -p "$repo5"
cat > "$repo5/test_handler.py" <<'EOF'
import pytest

@pytest.mark.skip(reason="not implemented")
def test_handler():
    pass
EOF
PROJECT_LANG="Python"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo5" "error" || rc=$?
assert_eq "1" "$rc" "Python @pytest.mark.skip returns error"

# Test 6: Python @pytest.mark.skipif NOT detected
echo "Test 6: Python @pytest.mark.skipif NOT detected"
repo6="$TMPDIR_ROOT/py-skipif"
mkdir -p "$repo6"
cat > "$repo6/test_handler.py" <<'EOF'
import pytest

@pytest.mark.skipif(sys.platform == "win32", reason="not on windows")
def test_handler():
    assert True
EOF
PROJECT_LANG="Python"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo6" "error" || rc=$?
assert_eq "0" "$rc" "Python @pytest.mark.skipif not flagged"

# ─── JS/TS Tests ────────────────────────────────────────────────────────────

echo ""
echo "=== JS/TS stub detection ==="

# Test 7: JS it.skip detected
echo "Test 7: JS it.skip() detected"
repo7="$TMPDIR_ROOT/js-skip"
mkdir -p "$repo7"
cat > "$repo7/handler.test.ts" <<'EOF'
describe('handler', () => {
  it.skip('should work', () => {
    expect(true).toBe(true);
  });
});
EOF
PROJECT_LANG="Node/JS/TS"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo7" "error" || rc=$?
assert_eq "1" "$rc" "JS it.skip returns error"

# Test 8: JS xit detected
echo "Test 8: JS xit() detected"
repo8="$TMPDIR_ROOT/js-xit"
mkdir -p "$repo8"
cat > "$repo8/handler.test.js" <<'EOF'
describe('handler', () => {
  xit('should work', () => {
    expect(true).toBe(true);
  });
});
EOF
PROJECT_LANG="Node/JS/TS"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo8" "error" || rc=$?
assert_eq "1" "$rc" "JS xit returns error"

# Test 9: JS test.todo detected
echo "Test 9: JS test.todo() detected"
repo9="$TMPDIR_ROOT/js-todo"
mkdir -p "$repo9"
cat > "$repo9/handler.spec.ts" <<'EOF'
test.todo('implement handler tests');
EOF
PROJECT_LANG="Node/JS/TS"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo9" "error" || rc=$?
assert_eq "1" "$rc" "JS test.todo returns error"

# Test 10: JS clean test NOT detected
echo "Test 10: JS clean test not flagged"
repo10="$TMPDIR_ROOT/js-clean"
mkdir -p "$repo10"
cat > "$repo10/handler.test.ts" <<'EOF'
describe('handler', () => {
  it('should work', () => {
    expect(true).toBe(true);
  });
});
EOF
PROJECT_LANG="Node/JS/TS"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo10" "error" || rc=$?
assert_eq "0" "$rc" "JS clean test not flagged"

# Test 11: Node-Monorepo also works
echo "Test 11: Node-Monorepo uses same detection"
PROJECT_LANG="Node-Monorepo"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo7" "error" || rc=$?
assert_eq "1" "$rc" "Node-Monorepo detects it.skip"

# ─── Rust Tests ─────────────────────────────────────────────────────────────

echo ""
echo "=== Rust stub detection ==="

# Test 12: Rust #[ignore] detected
echo "Test 12: Rust #[ignore] detected"
repo12="$TMPDIR_ROOT/rust-ignore"
mkdir -p "$repo12/src"
cat > "$repo12/src/lib.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    #[ignore]
    fn test_handler() {
        assert!(true);
    }
}
EOF
PROJECT_LANG="Rust"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo12" "error" || rc=$?
assert_eq "1" "$rc" "Rust #[ignore] returns error"

# Test 13: Rust clean test NOT detected
echo "Test 13: Rust clean test not flagged"
repo13="$TMPDIR_ROOT/rust-clean"
mkdir -p "$repo13/src"
cat > "$repo13/src/lib.rs" <<'EOF'
#[cfg(test)]
mod tests {
    #[test]
    fn test_handler() {
        assert!(true);
    }
}
EOF
PROJECT_LANG="Rust"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo13" "error" || rc=$?
assert_eq "0" "$rc" "Rust clean test not flagged"

# ─── Unknown language ──────────────────────────────────────────────────────

echo ""
echo "=== Unknown language ==="

# Test 14: Unknown language skips detection
echo "Test 14: Unknown language produces empty skip_files"
PROJECT_LANG="unknown"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "error" || rc=$?
assert_eq "0" "$rc" "Unknown lang returns 0 (no detection)"

# Test 15: Makefile language skips detection
echo "Test 15: Makefile language skips detection"
PROJECT_LANG="Makefile"
PROJECT_TEST_CMD="true"
PROJECT_WORK_DIR="."
LAST_TEST_OUTPUT=""
rc=0
verify_tests "$repo" "error" || rc=$?
assert_eq "0" "$rc" "Makefile lang returns 0 (no detection)"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
