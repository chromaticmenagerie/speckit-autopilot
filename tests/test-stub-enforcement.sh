#!/usr/bin/env bash
# test-stub-enforcement.sh — Unit tests for STUB_ENFORCEMENT_LEVEL config variable
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

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== STUB_ENFORCEMENT_LEVEL Tests ==="

# Test 1: top-level default is "warn"
echo "Test 1: top-level default in autopilot-lib.sh is 'warn'"
# Source only the defaults block (lines before logging section)
_default=$(grep '^STUB_ENFORCEMENT_LEVEL=' "$SRC_DIR/autopilot-lib.sh" | head -1)
assert_eq 'STUB_ENFORCEMENT_LEVEL="warn"' "$_default" "top-level default is warn"

# Test 2: belt-and-suspenders default in load_project_config()
echo "Test 2: belt-and-suspenders default exists in load_project_config()"
_belt=$(grep 'STUB_ENFORCEMENT_LEVEL=.*:-' "$SRC_DIR/autopilot-lib.sh" | sed 's/^[[:space:]]*//' || true)
assert_eq 'STUB_ENFORCEMENT_LEVEL="${STUB_ENFORCEMENT_LEVEL:-warn}"' \
    "$_belt" \
    "belt-and-suspenders default fallback to warn"

# Test 3: project.env template contains STUB_ENFORCEMENT_LEVEL
echo "Test 3: detect-project.sh template includes STUB_ENFORCEMENT_LEVEL"
_tmpl=$(grep '^STUB_ENFORCEMENT_LEVEL=' "$SRC_DIR/autopilot-detect-project.sh" || true)
assert_eq 'STUB_ENFORCEMENT_LEVEL="warn"' "$_tmpl" "template default is warn"

# Test 4: load_project_config sets default when variable missing from env file
echo "Test 4: load_project_config defaults to 'warn' when not in project.env"
(
    # Build a minimal project.env without STUB_ENFORCEMENT_LEVEL
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    mkdir -p "$tmpdir/.specify"
    cat > "$tmpdir/.specify/project.env" <<ENVEOF
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
BASE_BRANCH="main"
ENVEOF
    # Stub log so sourcing autopilot-lib.sh works
    unset STUB_ENFORCEMENT_LEVEL 2>/dev/null || true
    # Source common.sh and autopilot-lib.sh to get load_project_config
    source "$SRC_DIR/common.sh"
    # Override get_repo_root so it doesn't fail
    get_repo_root() { echo "$tmpdir"; }
    source "$SRC_DIR/autopilot-lib.sh"
    load_project_config "$tmpdir"
    echo "$STUB_ENFORCEMENT_LEVEL"
)
_val=$( (
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    mkdir -p "$tmpdir/.specify"
    cat > "$tmpdir/.specify/project.env" <<ENVEOF
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
BASE_BRANCH="main"
ENVEOF
    unset STUB_ENFORCEMENT_LEVEL 2>/dev/null || true
    source "$SRC_DIR/common.sh"
    get_repo_root() { echo "$tmpdir"; }
    source "$SRC_DIR/autopilot-lib.sh"
    load_project_config "$tmpdir"
    echo "$STUB_ENFORCEMENT_LEVEL"
) 2>/dev/null )
assert_eq "warn" "$_val" "defaults to warn when missing from project.env"

# Test 5: load_project_config preserves value when set in project.env
echo "Test 5: load_project_config preserves 'error' from project.env"
_val=$( (
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    mkdir -p "$tmpdir/.specify"
    cat > "$tmpdir/.specify/project.env" <<ENVEOF
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
BASE_BRANCH="main"
STUB_ENFORCEMENT_LEVEL="error"
ENVEOF
    unset STUB_ENFORCEMENT_LEVEL 2>/dev/null || true
    source "$SRC_DIR/common.sh"
    get_repo_root() { echo "$tmpdir"; }
    source "$SRC_DIR/autopilot-lib.sh"
    load_project_config "$tmpdir"
    echo "$STUB_ENFORCEMENT_LEVEL"
) 2>/dev/null )
assert_eq "error" "$_val" "preserves 'error' from project.env"

# Test 6: load_project_config preserves "off" from project.env
echo "Test 6: load_project_config preserves 'off' from project.env"
_val=$( (
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT
    mkdir -p "$tmpdir/.specify"
    cat > "$tmpdir/.specify/project.env" <<ENVEOF
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR="."
BASE_BRANCH="main"
STUB_ENFORCEMENT_LEVEL="off"
ENVEOF
    unset STUB_ENFORCEMENT_LEVEL 2>/dev/null || true
    source "$SRC_DIR/common.sh"
    get_repo_root() { echo "$tmpdir"; }
    source "$SRC_DIR/autopilot-lib.sh"
    load_project_config "$tmpdir"
    echo "$STUB_ENFORCEMENT_LEVEL"
) 2>/dev/null )
assert_eq "off" "$_val" "preserves 'off' from project.env"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
