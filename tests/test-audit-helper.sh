#!/usr/bin/env bash
# test-audit-helper.sh — Verify _write_force_skip_audit and _file_hash
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

assert_file_exists() {
    local file="$1" msg="${2:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ -f "$file" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: file '$file' does not exist"
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
        echo "  ✗ $msg: output does not contain '$needle'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a fake git repo so git commands don't fail fatally
git -C "$TMPDIR_TEST" init -q
git -C "$TMPDIR_TEST" config user.email "test@test.com"
git -C "$TMPDIR_TEST" config user.name "Test"
# Initial commit so git commit works
touch "$TMPDIR_TEST/.gitkeep"
git -C "$TMPDIR_TEST" add . && git -C "$TMPDIR_TEST" commit -m "init" -q

# Source the library (needs AUTOPILOT_LOG, BASE_BRANCH)
AUTOPILOT_LOG=""
BASE_BRANCH="master"
GH_ENABLED=false
source "$SRC_DIR/autopilot-lib.sh"

# Stub functions not needed
find_pen_file() { echo ""; }
is_epic_merged() { return 1; }

# ─── Test: _write_force_skip_audit writes ephemeral log ─────────────────────

echo "Test: _write_force_skip_audit writes ephemeral log"

repo="$TMPDIR_TEST"
mkdir -p "$repo/.specify/logs" "$repo/specs/001-test-epic"

_write_force_skip_audit "$repo" "security-review" "001" "001-test-epic" \
    "3" "FR-001: NOT_FOUND\nFR-002: PARTIAL\nFR-003: NOT_FOUND" "WARN" 2>/dev/null

ephemeral_log="$repo/.specify/logs/gate-skipped-findings.log"
assert_file_exists "$ephemeral_log" "ephemeral log created"
content=$(cat "$ephemeral_log")
assert_contains "$content" "WARN|security-review|3 findings|" "ephemeral log has correct format"

# ─── Test: skipped-findings.md created with correct format ──────────────────

echo "Test: skipped-findings.md created with correct format"

skipped="$repo/specs/001-test-epic/skipped-findings.md"
assert_file_exists "$skipped" "skipped-findings.md created"
skipped_content=$(cat "$skipped")
assert_contains "$skipped_content" "# Skipped Findings Audit Trail" "has header"
assert_contains "$skipped_content" "Epic: 001" "has epic number"
assert_contains "$skipped_content" "001-test-epic" "has short name"
assert_contains "$skipped_content" "security-review" "has gate name"
assert_contains "$skipped_content" "3 findings force-skipped" "has findings count"

# ─── Test: second call appends (does not overwrite) ─────────────────────────

echo "Test: second audit call appends to existing file"

_write_force_skip_audit "$repo" "requirements-verification" "001" "001-test-epic" \
    "1" "FR-004: NOT_FOUND" "ERROR" 2>/dev/null

skipped_content=$(cat "$skipped")
assert_contains "$skipped_content" "security-review" "still has first gate"
assert_contains "$skipped_content" "requirements-verification" "has second gate"

# ─── Test: _file_hash works on macOS (shasum) ──────────────────────────────

echo "Test: _file_hash returns consistent hash"

hash_file="$TMPDIR_TEST/hashme.txt"
echo "hello world" > "$hash_file"
hash1=$(_file_hash "$hash_file")
hash2=$(_file_hash "$hash_file")
assert_eq "$hash1" "$hash2" "same file produces same hash"

# Verify it's a real hash (64 hex chars for sha256)
len=${#hash1}
TESTS_RUN=$((TESTS_RUN + 1))
if [[ $len -eq 64 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ hash is 64 chars (sha256)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ hash length: expected 64, got $len (hash: $hash1)"
fi

# ─── Test: _file_hash returns "missing" for nonexistent file ────────────────

echo "Test: _file_hash returns 'missing' for nonexistent file"

result=$(_file_hash "$TMPDIR_TEST/nonexistent")
assert_eq "missing" "$result" "returns 'missing' for nonexistent file"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
