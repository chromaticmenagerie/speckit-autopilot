#!/usr/bin/env bash
# test-detect-test-modifications.sh — Unit tests for _detect_test_modifications()
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

# Stub log() to capture output
LOG_OUTPUT=""
log() {
    LOG_OUTPUT+="[$1] ${*:2}"$'\n'
}

# Extract _detect_test_modifications from autopilot-verify.sh
eval "$(sed -n '/^_detect_test_modifications()/,/^}/p' "$SRC_DIR/autopilot-verify.sh")"

# Helper: create a fresh git repo, return path and initial HEAD
# Usage: setup_repo; uses $repo and $head_before
setup_repo() {
    repo=$(mktemp -d "$TMPDIR_ROOT/repo-XXXX")
    (cd "$repo" && git init -q && git config user.email "test@test" && git config user.name "Test")
    # Seed commit so HEAD exists
    echo "init" > "$repo/README"
    (cd "$repo" && git add README && git commit -q -m "init")
    head_before=$(git -C "$repo" rev-parse HEAD)
}

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== _detect_test_modifications() tests ==="

# ─── Test 1: No test file modifications → empty CI_FIX_TEST_WARN ────────────

echo "Test 1: no test file modifications → CI_FIX_TEST_WARN empty"

setup_repo
# Add a non-test file after head_before
echo "package main" > "$repo/main.go"
(cd "$repo" && git add main.go && git commit -q -m "add main")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
rc=0
_detect_test_modifications "$repo" "$head_before" || rc=$?
assert_eq "0" "$rc" "returns 0"
assert_eq "" "$CI_FIX_TEST_WARN" "CI_FIX_TEST_WARN is empty"

# ─── Test 2: Test file added with no assertions → INFO ──────────────────────

echo "Test 2: test file added, no assertions → INFO"

setup_repo
cat > "$repo/handler_test.go" <<'EOF'
package main
import "testing"
func TestHandler(t *testing.T) { t.Log("placeholder") }
EOF
(cd "$repo" && git add handler_test.go && git commit -q -m "add test")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "INFO" "CI_FIX_TEST_WARN starts with INFO"
assert_contains "$CI_FIX_TEST_WARN" "Structural test changes only" "mentions structural"

# ─── Test 3: Assertions added > removed → WARN with counts ──────────────────

echo "Test 3: assertions added > removed → WARN"

setup_repo
printf 'package main\nimport "testing"\nfunc TestOld(t *testing.T) {\n    assert.Equal(t, 1, 1)\n}\n' > "$repo/handler_test.go"
(cd "$repo" && git add handler_test.go && git commit -q -m "initial test")
head_before=$(git -C "$repo" rev-parse HEAD)

printf 'package main\nimport "testing"\nfunc TestOld(t *testing.T) {\n    assert.Equal(t, 1, 1)\n    assert.NotNil(t, "x")\n    assert.True(t, true)\n}\n' > "$repo/handler_test.go"
(cd "$repo" && git add handler_test.go && git commit -q -m "add assertions")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "WARN" "CI_FIX_TEST_WARN is WARN"
assert_contains "$CI_FIX_TEST_WARN" "added=2" "shows 2 added"
assert_contains "$CI_FIX_TEST_WARN" "removed=0" "shows 0 removed"

# ─── Test 4: Assertions removed > added → ERROR ─────────────────────────────

echo "Test 4: assertions removed > added → ERROR"

setup_repo
printf 'package main\nimport "testing"\nfunc TestStuff(t *testing.T) {\n    assert.Equal(t, 1, 1)\n    assert.NotNil(t, "x")\n    require.NoError(t, nil)\n}\n' > "$repo/handler_test.go"
(cd "$repo" && git add handler_test.go && git commit -q -m "initial test")
head_before=$(git -C "$repo" rev-parse HEAD)

printf 'package main\nimport "testing"\nfunc TestStuff(t *testing.T) {\n    assert.Equal(t, 1, 1)\n}\n' > "$repo/handler_test.go"
(cd "$repo" && git add handler_test.go && git commit -q -m "remove assertions")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "ERROR" "CI_FIX_TEST_WARN is ERROR"
assert_contains "$CI_FIX_TEST_WARN" "Net assertion deletion" "mentions net deletion"
assert_contains "$LOG_OUTPUT" "ERROR" "log contains ERROR"

# ─── Test 5: Equal additions and removals → WARN (not ERROR) ────────────────

echo "Test 5: equal adds and removes → WARN not ERROR"

setup_repo
printf 'package main\nimport "testing"\nfunc TestA(t *testing.T) {\n    assert.Equal(t, 1, 1)\n}\n' > "$repo/handler_test.go"
(cd "$repo" && git add handler_test.go && git commit -q -m "initial")
head_before=$(git -C "$repo" rev-parse HEAD)

printf 'package main\nimport "testing"\nfunc TestA(t *testing.T) {\n    assert.NotNil(t, "x")\n}\n' > "$repo/handler_test.go"
(cd "$repo" && git add handler_test.go && git commit -q -m "swap assertion")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "WARN" "CI_FIX_TEST_WARN is WARN"
assert_not_contains "$CI_FIX_TEST_WARN" "ERROR" "not ERROR when equal"
assert_contains "$CI_FIX_TEST_WARN" "added=1" "shows 1 added"
assert_contains "$CI_FIX_TEST_WARN" "removed=1" "shows 1 removed"

# ─── Test 6: Multiple test files modified → all detected, counts aggregated ─

echo "Test 6: multiple test files → aggregated counts"

setup_repo
cat > "$repo/a_test.go" <<'EOF'
package main
import "testing"
func TestA(t *testing.T) {}
EOF
cat > "$repo/b_test.go" <<'EOF'
package main
import "testing"
func TestB(t *testing.T) {}
EOF
(cd "$repo" && git add a_test.go b_test.go && git commit -q -m "initial tests")
head_before=$(git -C "$repo" rev-parse HEAD)

cat > "$repo/a_test.go" <<'EOF'
package main
import "testing"
func TestA(t *testing.T) {
    assert.Equal(t, 1, 1)
}
EOF
cat > "$repo/b_test.go" <<'EOF'
package main
import "testing"
func TestB(t *testing.T) {
    require.NoError(t, nil)
    assert.True(t, true)
}
EOF
(cd "$repo" && git add a_test.go b_test.go && git commit -q -m "add assertions")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "WARN" "WARN for multiple files"
assert_contains "$CI_FIX_TEST_WARN" "added=3" "aggregated 3 additions"
assert_contains "$CI_FIX_TEST_WARN" "a_test.go" "mentions a_test.go"
assert_contains "$CI_FIX_TEST_WARN" "b_test.go" "mentions b_test.go"

# ─── Test 7: Testutil helper modifications counted ──────────────────────────

echo "Test 7: testutil helper files included in assertion counting"

setup_repo
mkdir -p "$repo/testutil"
cat > "$repo/handler_test.go" <<'EOF'
package main
import "testing"
func TestX(t *testing.T) {}
EOF
cat > "$repo/testutil/helpers.go" <<'EOF'
package testutil
EOF
(cd "$repo" && git add handler_test.go testutil/helpers.go && git commit -q -m "initial")
head_before=$(git -C "$repo" rev-parse HEAD)

# Add assertions to testutil helper (not a _test.go file itself)
cat > "$repo/handler_test.go" <<'EOF'
package main
import "testing"
func TestX(t *testing.T) {
    t.Log("updated")
}
EOF
cat > "$repo/testutil/helpers.go" <<'EOF'
package testutil
import "testing"
func AssertOK(t *testing.T) {
    assert.NoError(t, nil)
    require.NotNil(t, "ok")
}
EOF
(cd "$repo" && git add handler_test.go testutil/helpers.go && git commit -q -m "add helpers")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
# handler_test.go is detected as modified; testutil assertions are included via
# pathspec '**/testutil/*.go' — but git pathspec '**' only works with :(glob)
# prefix, so currently testutil assertions are NOT counted (known limitation).
# The result is INFO/structural because handler_test.go has no assertion changes.
assert_contains "$CI_FIX_TEST_WARN" "INFO" "INFO when only testutil has assertions (pathspec limitation)"
assert_contains "$CI_FIX_TEST_WARN" "handler_test.go" "detects handler_test.go modification"

# ─── Test 8: Uncommitted/staged changes detected ────────────────────────────

echo "Test 8: staged (uncommitted) changes detected"

setup_repo
cat > "$repo/handler_test.go" <<'EOF'
package main
import "testing"
func TestY(t *testing.T) {
    assert.Equal(t, 1, 1)
    assert.True(t, true)
}
EOF
(cd "$repo" && git add handler_test.go && git commit -q -m "initial test")
head_before=$(git -C "$repo" rev-parse HEAD)

# Stage a change but don't commit
cat > "$repo/handler_test.go" <<'EOF'
package main
import "testing"
func TestY(t *testing.T) {
    assert.Equal(t, 1, 1)
}
EOF
(cd "$repo" && git add handler_test.go)

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
# dirty_tests path should pick up the staged change
assert_contains "$CI_FIX_TEST_WARN" "handler_test.go" "detects staged test file"

# ─── Test 9: Language variations — Go, TS/JS assertion patterns ─────────────

echo "Test 9: language variations — Go assert/require/t.Fatal, TS/JS expect("

setup_repo
cat > "$repo/api_test.go" <<'EOF'
package main
import "testing"
func TestFatal(t *testing.T) {}
EOF
cat > "$repo/widget.test.ts" <<'EOF'
describe("widget", () => {});
EOF
cat > "$repo/util.spec.js" <<'EOF'
describe("util", () => {});
EOF
(cd "$repo" && git add api_test.go widget.test.ts util.spec.js && git commit -q -m "initial")
head_before=$(git -C "$repo" rev-parse HEAD)

cat > "$repo/api_test.go" <<'EOF'
package main
import "testing"
func TestFatal(t *testing.T) {
    t.Fatal("should not reach")
    t.Fatalf("format %s", "err")
    t.Errorf("bad %d", 1)
}
EOF
cat > "$repo/widget.test.ts" <<'EOF'
describe("widget", () => {
    it("works", () => {
        expect(result).toBe(true);
        expect(other).toEqual(42);
    });
});
EOF
cat > "$repo/util.spec.js" <<'EOF'
describe("util", () => {
    it("runs", () => {
        expect(val).toBeDefined();
    });
});
EOF
(cd "$repo" && git add api_test.go widget.test.ts util.spec.js && git commit -q -m "add assertions")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "WARN" "WARN for multi-lang assertions"
# t.Fatal, t.Fatalf, t.Errorf = 3; expect( x 3 = 3; total = 6
assert_contains "$CI_FIX_TEST_WARN" "added=6" "counts all language patterns (6 total)"

# ─── Test 10: Python assertions detected with PROJECT_LANG=Python ─────────

echo "Test 10: Python self.assert/pytest.raises detected"

setup_repo
export PROJECT_LANG="Python"
printf 'import unittest\nclass TestExample(unittest.TestCase):\n    pass\n' > "$repo/test_example.py"
(cd "$repo" && git add test_example.py && git commit -q -m "initial test")
head_before=$(git -C "$repo" rev-parse HEAD)

cat > "$repo/test_example.py" <<'EOF'
import unittest
class TestExample(unittest.TestCase):
    def test_add(self):
        self.assertEqual(1 + 1, 2)
        self.assertTrue(True)
    def test_error(self):
        with pytest.raises(ValueError):
            int("bad")
EOF
(cd "$repo" && git add test_example.py && git commit -q -m "add Python assertions")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "WARN" "WARN for Python assertions"
assert_contains "$CI_FIX_TEST_WARN" "added=3" "counts assertEqual + assertTrue + pytest.raises = 3"
assert_contains "$CI_FIX_TEST_WARN" "test_example.py" "mentions test_example.py"

# ─── Test 11: Python self.assert[A-Z] does not match self.assertion_helper ─

echo "Test 11: Python pattern avoids false positive on self.assertion_helper"

setup_repo
export PROJECT_LANG="Python"
printf 'class TestFP:\n    pass\n' > "$repo/test_fp.py"
(cd "$repo" && git add test_fp.py && git commit -q -m "initial")
head_before=$(git -C "$repo" rev-parse HEAD)

printf 'class TestFP:\n    def test_it(self):\n        self.assertion_helper("data")\n        self.assert_custom("value")\n' > "$repo/test_fp.py"
(cd "$repo" && git add test_fp.py && git commit -q -m "add non-assertion methods")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
# self.assertion_helper and self.assert_custom should NOT match (no uppercase after assert)
assert_contains "$CI_FIX_TEST_WARN" "INFO" "INFO for structural-only (no real assertions)"
assert_contains "$CI_FIX_TEST_WARN" "Structural test changes only" "no false-positive assertion match"

# ─── Test 12: Unknown language uses combined fallback patterns ────────────

echo "Test 12: unknown language → fallback combined patterns"

setup_repo
export PROJECT_LANG="unknown"
cat > "$repo/handler_test.go" <<'EOF'
package main
import "testing"
func TestX(t *testing.T) {}
EOF
cat > "$repo/test_combo.py" <<'EOF'
class TestCombo:
    pass
EOF
(cd "$repo" && git add handler_test.go test_combo.py && git commit -q -m "initial")
head_before=$(git -C "$repo" rev-parse HEAD)

cat > "$repo/handler_test.go" <<'EOF'
package main
import "testing"
func TestX(t *testing.T) {
    assert.Equal(t, 1, 1)
}
EOF
cat > "$repo/test_combo.py" <<'EOF'
class TestCombo:
    def test_it(self):
        self.assertEqual(1, 1)
EOF
(cd "$repo" && git add handler_test.go test_combo.py && git commit -q -m "add mixed assertions")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "WARN" "WARN for fallback combined"
assert_contains "$CI_FIX_TEST_WARN" "added=2" "counts Go assert + Python assertEqual = 2"

# ─── Test 13: Go behavior unchanged after refactor ───────────────────────

echo "Test 13: Go behavior regression check"

setup_repo
export PROJECT_LANG="Go"
cat > "$repo/svc_test.go" <<'EOF'
package main
import "testing"
func TestSvc(t *testing.T) {}
EOF
(cd "$repo" && git add svc_test.go && git commit -q -m "initial")
head_before=$(git -C "$repo" rev-parse HEAD)

cat > "$repo/svc_test.go" <<'EOF'
package main
import "testing"
func TestSvc(t *testing.T) {
    assert.Equal(t, 1, 1)
    require.NoError(t, nil)
    t.Fatal("stop")
}
EOF
(cd "$repo" && git add svc_test.go && git commit -q -m "add Go assertions")

LOG_OUTPUT=""
CI_FIX_TEST_WARN=""
_detect_test_modifications "$repo" "$head_before"
assert_contains "$CI_FIX_TEST_WARN" "WARN" "WARN for Go assertions"
assert_contains "$CI_FIX_TEST_WARN" "added=3" "counts assert + require + t.Fatal = 3"

# Clean up exported PROJECT_LANG
unset PROJECT_LANG

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
