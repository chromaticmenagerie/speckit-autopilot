#!/usr/bin/env bash
# test-prefix-correction.sh — Test _correct_prefix() rename logic + edge cases
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

# Source library for log() (writes to stderr now)
AUTOPILOT_LOG=""
BASE_BRANCH="master"
source "$SRC_DIR/autopilot-lib.sh"

# Extract _correct_prefix from autopilot.sh
eval "$(sed -n '/^_correct_prefix()/,/^}/p' "$SRC_DIR/autopilot.sh")"

# ─── Test 1: Happy path — rename branch + directory ─────────────────────────

echo "Test 1: Happy path — 001-some-feature with epic 003 → 003-some-feature"

repo="$TMPDIR/repo-happy"
mkdir -p "$repo/specs/001-some-feature"
echo "# spec" > "$repo/specs/001-some-feature/spec.md"
git -C "$repo" init -q
git -C "$repo" add -A && git -C "$repo" commit -m "init" -q
git -C "$repo" checkout -b "001-some-feature" -q

result=$(_correct_prefix "$repo" "003" "001-some-feature" 2>/dev/null)
assert_eq "003-some-feature" "$result" "returns corrected name"
assert_eq "true" "$([[ -d "$repo/specs/003-some-feature" ]] && echo true || echo false)" "specs dir renamed"
assert_eq "false" "$([[ -d "$repo/specs/001-some-feature" ]] && echo true || echo false)" "old specs dir removed"
assert_eq "true" "$([[ -f "$repo/specs/003-some-feature/spec.md" ]] && echo true || echo false)" "spec.md survived rename"

current=$(git -C "$repo" branch --show-current)
assert_eq "003-some-feature" "$current" "branch renamed"

# ─── Test 2: No-op — prefix already correct ─────────────────────────────────

echo "Test 2: No-op — 003-some-feature with epic 003 → unchanged"

repo2="$TMPDIR/repo-noop"
mkdir -p "$repo2/specs/003-some-feature"
echo "# spec" > "$repo2/specs/003-some-feature/spec.md"
git -C "$repo2" init -q
git -C "$repo2" add -A && git -C "$repo2" commit -m "init" -q
git -C "$repo2" checkout -b "003-some-feature" -q

result=$(_correct_prefix "$repo2" "003" "003-some-feature" 2>/dev/null)
assert_eq "003-some-feature" "$result" "returns same name"
assert_eq "true" "$([[ -d "$repo2/specs/003-some-feature" ]] && echo true || echo false)" "specs dir unchanged"

# ─── Test 3: Collision — stale target branch exists ──────────────────────────

echo "Test 3: Collision — pre-existing 003-some-feature branch"

repo3="$TMPDIR/repo-collision"
mkdir -p "$repo3/specs/001-some-feature"
echo "# spec" > "$repo3/specs/001-some-feature/spec.md"
git -C "$repo3" init -q
git -C "$repo3" add -A && git -C "$repo3" commit -m "init" -q
# Create stale target branch
git -C "$repo3" checkout -b "003-some-feature" -q
git -C "$repo3" commit --allow-empty -m "stale" -q
# Switch to the wrong-prefix branch
git -C "$repo3" checkout -b "001-some-feature" -q

result=$(_correct_prefix "$repo3" "003" "001-some-feature" 2>/dev/null)
assert_eq "003-some-feature" "$result" "returns corrected name despite collision"

current=$(git -C "$repo3" branch --show-current)
assert_eq "003-some-feature" "$current" "branch renamed after deleting stale"

# ─── Test 4: No dash in name → error, returns original ──────────────────────

echo "Test 4: No dash — 'noprefix' → error, returns original"

repo4="$TMPDIR/repo-nodash"
mkdir -p "$repo4"
git -C "$repo4" init -q
git -C "$repo4" commit --allow-empty -m "init" -q

result=$(_correct_prefix "$repo4" "003" "noprefix" 2>/dev/null) || true
assert_eq "noprefix" "$result" "returns original name on error"

# ─── Test 5: Empty suffix after dash → error, returns original ──────────────

echo "Test 5: Empty suffix — '001-' → error (suffix is empty string)"

repo5="$TMPDIR/repo-emptysuffix"
mkdir -p "$repo5"
git -C "$repo5" init -q
git -C "$repo5" commit --allow-empty -m "init" -q

result=$(_correct_prefix "$repo5" "003" "001-" 2>/dev/null) || true
# "001-" after removing up to first dash gives "" which is empty → error path
assert_eq "001-" "$result" "returns original name when suffix is empty"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
