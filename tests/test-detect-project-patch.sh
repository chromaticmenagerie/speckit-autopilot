#!/usr/bin/env bash
# test-detect-project-patch.sh — Tests for --patch mode and CODEX_ENABLED
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
        echo "  PASS $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL $msg: expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL $msg: '$needle' not found in output"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | grep -qF "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL $msg: '$needle' unexpectedly found in output"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Stub log
log() { :; }

# Source helper functions
source "$SRC_DIR/autopilot-detect-tools.sh"

# ─── Unit tests for _extract_env_keys ────────────────────────────────────────

echo "Test: _extract_env_keys extracts variable names"

keyfile="$TMPDIR_ROOT/keys.env"
cat > "$keyfile" <<'EOF'
# comment line
PROJECT_TEST_CMD="pytest"
PROJECT_LINT_CMD="ruff check ."
# another comment
HAS_DOCKER="true"
# COMMENTED_OUT="no"
EOF

result=$(_extract_env_keys "$keyfile")
assert_contains "$result" "PROJECT_TEST_CMD" "_extract_env_keys finds PROJECT_TEST_CMD"
assert_contains "$result" "PROJECT_LINT_CMD" "_extract_env_keys finds PROJECT_LINT_CMD"
assert_contains "$result" "HAS_DOCKER" "_extract_env_keys finds HAS_DOCKER"
assert_not_contains "$result" "COMMENTED_OUT" "_extract_env_keys skips comments"

# ─── Unit tests for _patch_env_file ──────────────────────────────────────────

echo ""
echo "Test: _patch_env_file appends missing vars only"

existing="$TMPDIR_ROOT/existing.env"
template="$TMPDIR_ROOT/template.env"
cat > "$existing" <<'EOF'
PROJECT_TEST_CMD="pytest"
HAS_DOCKER="true"
EOF

cat > "$template" <<'EOF'
PROJECT_TEST_CMD="pytest"
HAS_DOCKER="true"
CODEX_ENABLED="true"
NEW_VAR="hello"
EOF

output=$(_patch_env_file "$existing" "$template")
assert_contains "$(cat "$existing")" 'CODEX_ENABLED="true"' "appends CODEX_ENABLED"
assert_contains "$(cat "$existing")" 'NEW_VAR="hello"' "appends NEW_VAR"
assert_contains "$output" "2 missing variable" "reports 2 missing"
# Existing values preserved
first_line=$(head -1 "$existing")
assert_eq 'PROJECT_TEST_CMD="pytest"' "$first_line" "preserves existing first line"

echo ""
echo "Test: _patch_env_file no-op when all vars present"

complete="$TMPDIR_ROOT/complete.env"
cat > "$complete" <<'EOF'
FOO="bar"
BAZ="qux"
EOF
template2="$TMPDIR_ROOT/template2.env"
cat > "$template2" <<'EOF'
FOO="bar"
BAZ="qux"
EOF

output=$(_patch_env_file "$complete" "$template2")
assert_contains "$output" "up to date" "reports up to date"
# File should not have patch header
assert_not_contains "$(cat "$complete")" "Added by --patch" "no patch header added"

echo ""
echo "Test: _patch_env_file idempotency — running twice produces no duplicates"

idem="$TMPDIR_ROOT/idem.env"
idem_tmpl="$TMPDIR_ROOT/idem_tmpl.env"
cat > "$idem" <<'EOF'
ALPHA="1"
EOF
cat > "$idem_tmpl" <<'EOF'
ALPHA="1"
BETA="2"
EOF

_patch_env_file "$idem" "$idem_tmpl" >/dev/null
_patch_env_file "$idem" "$idem_tmpl" >/dev/null
count=$(grep -c '^BETA=' "$idem")
assert_eq "1" "$count" "BETA appears exactly once after two patches"

# ─── Integration: --patch + --force → error ──────────────────────────────────

echo ""
echo "Test: --patch + --force → error"

repo="$TMPDIR_ROOT/repo-conflict"
mkdir -p "$repo/.specify"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

output=$("$SRC_DIR/autopilot-detect-project.sh" --patch --force 2>&1 || true)
assert_contains "$output" "mutually exclusive" "--patch --force errors"

# ─── Integration: --patch on missing file → fresh install ────────────────────

echo ""
echo "Test: --patch on missing file → falls back to fresh install"

repo="$TMPDIR_ROOT/repo-missing"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

output=$(cd "$repo" && "$SRC_DIR/autopilot-detect-project.sh" --patch 2>&1)
assert_eq "0" "$?" "exits 0"
assert_contains "$output" "no existing project.env" "warns about missing file"
# Should have created the file
test -f "$repo/.specify/project.env"
assert_eq "0" "$?" "creates project.env"

# ─── Integration: --patch with missing vars → appends ────────────────────────

echo ""
echo "Test: --patch with missing vars → appends only missing"

repo="$TMPDIR_ROOT/repo-patch"
mkdir -p "$repo/.specify"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

# Create a partial project.env (missing CODEX_ENABLED and STUB_ENFORCEMENT_LEVEL)
cat > "$repo/.specify/project.env" <<'EOF'
# partial project.env
PROJECT_TEST_CMD="my-custom-test"
PROJECT_LINT_CMD="my-lint"
PROJECT_WORK_DIR="."
PROJECT_BUILD_CMD=""
PROJECT_FORMAT_CMD=""
PROJECT_CI_CMD=""
PROJECT_FMT_CHECK_CMD=""
PROJECT_CODEGEN_CHECK_CMD=""
PROJECT_INTEGRATION_CMD=""
PROJECT_E2E_CMD=""
PROJECT_FE_PKG_MANAGER=""
PROJECT_FE_DIR=""
PROJECT_FE_INSTALL_CMD=""
HAS_DOCKER="false"
BASE_BRANCH="main"
HAS_CODERABBIT="false"
HAS_CODEX="false"
CODERABBIT_MAX_ROUNDS=3
HAS_REMOTE="false"
HAS_GH_CLI="false"
HAS_FRONTEND="false"
PROJECT_SECRET_SCAN_CMD=""
PROJECT_SECRET_TIER1_RULES=""
PROJECT_SECRET_SCAN_MODE="branch"
PROJECT_PREFLIGHT_TOOLS=""
CONVERGENCE_STALL_ROUNDS=2
MERGE_STRATEGY="merge"
PROJECT_LANG="unknown"
EOF

output=$(cd "$repo" && "$SRC_DIR/autopilot-detect-project.sh" --patch 2>&1)
# Should have added missing vars (CODEX_ENABLED, STUB_ENFORCEMENT_LEVEL)
env_content=$(cat "$repo/.specify/project.env")
assert_contains "$env_content" "CODEX_ENABLED=" "CODEX_ENABLED added by patch"
assert_contains "$env_content" "STUB_ENFORCEMENT_LEVEL=" "STUB_ENFORCEMENT_LEVEL added by patch"
# Custom value preserved
assert_contains "$env_content" 'PROJECT_TEST_CMD="my-custom-test"' "preserves custom test cmd"

# ─── Integration: CODEX_ENABLED in fresh template ────────────────────────────

echo ""
echo "Test: CODEX_ENABLED appears in freshly generated template"

repo="$TMPDIR_ROOT/repo-fresh"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

output=$(cd "$repo" && "$SRC_DIR/autopilot-detect-project.sh" 2>&1)
env_content=$(cat "$repo/.specify/project.env")
assert_contains "$env_content" 'CODEX_ENABLED=' "CODEX_ENABLED present in fresh template"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
