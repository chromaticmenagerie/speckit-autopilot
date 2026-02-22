#!/usr/bin/env bash
# test-detect-project.sh — Unit tests for _ensure_gitignore_logs()
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

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub log
log() { :; }

# Extract _ensure_gitignore_logs from detect-project
eval "$(sed -n '/^_ensure_gitignore_logs()/,/^}/p' "$SRC_DIR/autopilot-detect-project.sh")"

# ─── Test: no .gitignore → creates file with entry ─────────────────────────

echo "Test: no .gitignore → creates file with .specify/logs/ entry"

repo="$TMPDIR/repo-no-gitignore"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

_ensure_gitignore_logs "$repo"
assert_eq "0" "$?" "function succeeds"
assert_eq ".specify/logs/" "$(cat "$repo/.gitignore")" "creates .gitignore with entry"

# ─── Test: .gitignore exists without entry → appends ───────────────────────

echo "Test: .gitignore exists without entry → appends .specify/logs/"

repo="$TMPDIR/repo-existing-gitignore"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q
echo "node_modules/" > "$repo/.gitignore"

_ensure_gitignore_logs "$repo"
result="$(grep -cxF '.specify/logs/' "$repo/.gitignore")"
assert_eq "1" "$result" "appends .specify/logs/ entry"

first_line="$(head -1 "$repo/.gitignore")"
assert_eq "node_modules/" "$first_line" "preserves existing content"

# ─── Test: .gitignore already has entry → idempotent ───────────────────────

echo "Test: .gitignore already has entry → no change (idempotent)"

repo="$TMPDIR/repo-idempotent"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q
printf "node_modules/\n.specify/logs/\n" > "$repo/.gitignore"

before="$(cat "$repo/.gitignore")"
_ensure_gitignore_logs "$repo"
after="$(cat "$repo/.gitignore")"
assert_eq "$before" "$after" "file unchanged when entry already present"

count="$(grep -cxF '.specify/logs/' "$repo/.gitignore")"
assert_eq "1" "$count" "no duplicate entries"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
