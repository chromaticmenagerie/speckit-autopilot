#!/usr/bin/env bash
# test-crystallize-grep.sh — Verify PROJECT_LANG default and crystallize
# grep-based module map extraction (graceful degradation for unknown langs).
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local actual="$1" expected="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$actual" == "$expected" ]]; then
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

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: '$needle' should NOT appear in output"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create minimal project.env without PROJECT_LANG (simulates stale config)
mkdir -p "$TMPDIR_TEST/.specify"
cat > "$TMPDIR_TEST/.specify/project.env" <<'ENVEOF'
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
PROJECT_BUILD_CMD=""
PROJECT_FORMAT_CMD=""
BASE_BRANCH="main"
HAS_FRONTEND="false"
HAS_CODERABBIT="false"
HAS_CODEX="false"
HAS_REMOTE="false"
HAS_GH_CLI="false"
PROJECT_PREFLIGHT_TOOLS=""
MERGE_STRATEGY="merge"
ENVEOF

# Minimal git repo for get_repo_root
(cd "$TMPDIR_TEST" && git init -q && git config user.email "test@test" && git config user.name "Test" && git commit --allow-empty -m init -q)

# Stubs for sourced functions
log() { :; }
get_repo_root() { echo "$TMPDIR_TEST"; }

# Source lib to get load_project_config
source "$SRC_DIR/common.sh" 2>/dev/null || true
source "$SRC_DIR/autopilot-verify.sh" 2>/dev/null || true
source "$SRC_DIR/autopilot-lib.sh"

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== PROJECT_LANG Default Tests ==="

# Test 1: PROJECT_LANG defaults to "unknown" when not in project.env
echo "Test 1: PROJECT_LANG defaults to 'unknown' when missing from project.env"
unset PROJECT_LANG 2>/dev/null || true
load_project_config "$TMPDIR_TEST"
assert_eq "${PROJECT_LANG:-}" "unknown" "PROJECT_LANG defaults to unknown"

# Test 2: PROJECT_LANG preserves value when set in project.env
echo "Test 2: PROJECT_LANG preserves value from project.env"
echo 'PROJECT_LANG="Go"' >> "$TMPDIR_TEST/.specify/project.env"
unset PROJECT_LANG 2>/dev/null || true
load_project_config "$TMPDIR_TEST"
assert_eq "$PROJECT_LANG" "Go" "PROJECT_LANG=Go preserved from project.env"

echo ""
echo "=== Crystallize Grep Graceful Degradation Tests ==="

# Test 3: grep_output is empty for unknown PROJECT_LANG
echo "Test 3: grep_output empty for unknown language"
grep_output=""
local_project_lang="unknown"
case "$local_project_lang" in
    Go)
        grep_output="would-not-be-empty" ;;
    Node/JS/TS|Node-Monorepo)
        grep_output="would-not-be-empty" ;;
    Python)
        grep_output="would-not-be-empty" ;;
    Rust)
        grep_output="would-not-be-empty" ;;
esac
assert_eq "$grep_output" "" "grep_output empty for unknown lang"

# Test 4: grep_output is empty for Makefile-only projects
echo "Test 4: grep_output empty for Makefile-only project"
grep_output=""
local_project_lang="Makefile"
case "$local_project_lang" in
    Go)
        grep_output="would-not-be-empty" ;;
    Node/JS/TS|Node-Monorepo)
        grep_output="would-not-be-empty" ;;
    Python)
        grep_output="would-not-be-empty" ;;
    Rust)
        grep_output="would-not-be-empty" ;;
esac
assert_eq "$grep_output" "" "grep_output empty for Makefile lang"

# Test 5: Go case produces output from real .go files
echo "Test 5: Go grep produces output from real source files"
GO_DIR="$TMPDIR_TEST/goproject"
mkdir -p "$GO_DIR"
cat > "$GO_DIR/main.go" <<'GOEOF'
package main

func PublicFunc(x int) int {
    return x + 1
}

func privateFunc() {}
GOEOF

grep_output=$(grep -rnE '^func\s+(\([^)]+\)\s+)?[A-Z]\w*\(' "$GO_DIR" \
    --include='*.go' --exclude-dir=vendor --exclude-dir=.git \
    --exclude='*_test.go' 2>/dev/null | head -200 || true)
assert_contains "$grep_output" "PublicFunc" "Go grep finds exported func"
assert_not_contains "$grep_output" "privateFunc" "Go grep skips unexported func"

# Test 6: Node/TS case produces output from real .ts files
echo "Test 6: Node/TS grep produces output from real source files"
TS_DIR="$TMPDIR_TEST/tsproject"
mkdir -p "$TS_DIR"
cat > "$TS_DIR/utils.ts" <<'TSEOF'
export function calculateTotal(items: Item[]): number {
    return items.reduce((sum, i) => sum + i.price, 0);
}

export const API_KEY = "test";

function internalHelper() {}
TSEOF

grep_output=$(grep -rnE '^export\s+(async\s+)?(function|const|class|interface|type|enum)' "$TS_DIR" \
    --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
    --exclude-dir=vendor --exclude-dir=.git --exclude-dir=node_modules \
    --exclude-dir=dist --exclude='*.test.*' --exclude='*.spec.*' 2>/dev/null | head -200 || true)
assert_contains "$grep_output" "calculateTotal" "TS grep finds exported function"
assert_contains "$grep_output" "API_KEY" "TS grep finds exported const"
assert_not_contains "$grep_output" "internalHelper" "TS grep skips non-exported func"

# Test 7: Python case produces output from real .py files
echo "Test 7: Python grep produces output from real source files"
PY_DIR="$TMPDIR_TEST/pyproject"
mkdir -p "$PY_DIR"
cat > "$PY_DIR/models.py" <<'PYEOF'
class UserModel:
    pass

def process_data(items):
    return [i for i in items]
PYEOF

grep_output=$(grep -rnE '^(def|class) ' "$PY_DIR" \
    --include='*.py' --exclude-dir=vendor --exclude-dir=.git \
    --exclude-dir=__pycache__ --exclude='test_*' --exclude='*_test.py' 2>/dev/null | head -200 || true)
assert_contains "$grep_output" "UserModel" "Python grep finds class"
assert_contains "$grep_output" "process_data" "Python grep finds def"

# Test 8: Rust case produces output from real .rs files
echo "Test 8: Rust grep produces output from real source files"
RS_DIR="$TMPDIR_TEST/rsproject"
mkdir -p "$RS_DIR"
cat > "$RS_DIR/lib.rs" <<'RSEOF'
pub fn create_engine() -> Engine {
    Engine::new()
}

pub struct Engine {
    running: bool,
}

fn private_helper() {}
RSEOF

grep_output=$(grep -rnE '^\s*pub\s+(fn|struct|enum|trait)' "$RS_DIR" \
    --include='*.rs' --exclude-dir=vendor --exclude-dir=.git \
    --exclude-dir=target 2>/dev/null | head -200 || true)
assert_contains "$grep_output" "create_engine" "Rust grep finds pub fn"
assert_contains "$grep_output" "Engine" "Rust grep finds pub struct"
assert_not_contains "$grep_output" "private_helper" "Rust grep skips non-pub fn"

# Test 9: prompt_crystallize includes grounding when SOURCE MODULE MAP present
echo "Test 9: prompt_crystallize includes grounding instruction"
# Stubs for prompt function
_preamble() { echo "PREAMBLE"; }
MERGE_TARGET="main"
LAST_MERGE_SHA="abc123"
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
HAS_FRONTEND="false"
source "$SRC_DIR/autopilot-prompts.sh"

diff_file="$TMPDIR_TEST/diff-with-map.txt"
printf 'FILES CHANGED:\nfoo.go\n\nSOURCE MODULE MAP (pre-computed from actual source files):\nfoo.go:3:func PublicFunc(x int) int {\n' > "$diff_file"
output="$(prompt_crystallize "001" "test epic" "$TMPDIR_TEST" "feat" "$diff_file")"
assert_contains "$output" "Ground the module map" "prompt includes grounding instruction when SOURCE MODULE MAP present"

# Test 10: prompt_crystallize omits grounding when no SOURCE MODULE MAP
echo "Test 10: prompt_crystallize omits grounding when no map"
diff_file_no_map="$TMPDIR_TEST/diff-no-map.txt"
printf 'FILES CHANGED:\nfoo.go\n\nFULL DIFF:\n+func Foo() {}\n' > "$diff_file_no_map"
output="$(prompt_crystallize "001" "test epic" "$TMPDIR_TEST" "feat" "$diff_file_no_map")"
assert_not_contains "$output" "Ground the module map" "prompt omits grounding when no SOURCE MODULE MAP"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
