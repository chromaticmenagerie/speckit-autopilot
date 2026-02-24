#!/usr/bin/env bash
# test-merge-target.sh — Unit tests for detect_merge_target()
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

# Source only common.sh and autopilot-lib.sh (avoid sourcing full autopilot)
# We need the log function and detect_merge_target; stub what's needed.

# Minimal stubs so autopilot-lib.sh can source without errors
AUTOPILOT_LOG=""
log() { :; }

# Source common.sh provides get_repo_root etc.
source "$SRC_DIR/common.sh"

# Override source inside autopilot-lib.sh — it already sourced common.sh
# We just need detect_merge_target and is_epic_merged
# Extract functions directly to avoid side-effect sourcing
eval "$(sed -n '/^detect_merge_target()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")"
eval "$(sed -n '/^is_epic_merged()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")"

# ─── Test: detect_merge_target — no staging branch ─────────────────────────

echo "Test: detect_merge_target — no staging branch → falls back to BASE_BRANCH"

repo="$TMPDIR/repo-no-staging"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

BASE_BRANCH="main"
result="$(detect_merge_target "$repo")"
assert_eq "main" "$result" "returns BASE_BRANCH when no staging exists"

BASE_BRANCH="master"
result="$(detect_merge_target "$repo")"
assert_eq "master" "$result" "returns master when BASE_BRANCH=master and no staging"

# ─── Test: detect_merge_target — local staging branch ──────────────────────

echo "Test: detect_merge_target — local staging branch exists"

repo="$TMPDIR/repo-local-staging"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q
git -C "$repo" branch staging

BASE_BRANCH="main"
result="$(detect_merge_target "$repo")"
assert_eq "staging" "$result" "returns staging when local staging branch exists"

# ─── Test: detect_merge_target — only origin/staging (remote tracking) ─────

echo "Test: detect_merge_target — only origin/staging exists"

# Create a bare remote with a staging branch
remote="$TMPDIR/remote-staging"
git init --bare -q "$remote"

repo="$TMPDIR/repo-remote-staging"
git clone -q "$remote" "$repo"
cd "$repo"
git commit --allow-empty -m "init" -q
git push -q origin main 2>/dev/null || git push -q origin master 2>/dev/null || true

# Create staging on remote (via bare repo)
git -C "$remote" branch staging HEAD 2>/dev/null || \
    git -C "$remote" branch staging "$(git -C "$remote" rev-parse HEAD)" 2>/dev/null
git -C "$repo" fetch -q origin

# Ensure no LOCAL staging branch (only origin/staging)
git -C "$repo" branch -D staging 2>/dev/null || true

BASE_BRANCH="main"
result="$(detect_merge_target "$repo")"
assert_eq "staging" "$result" "returns staging when only origin/staging exists"

# ─── Test: detect_merge_target — defaults to master when BASE_BRANCH unset ─

echo "Test: detect_merge_target — unset BASE_BRANCH defaults to master"

repo="$TMPDIR/repo-no-base"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

unset BASE_BRANCH
result="$(detect_merge_target "$repo")"
assert_eq "master" "$result" "returns master when BASE_BRANCH unset and no staging"
BASE_BRANCH="master"  # restore

# ─── Test: detect_merge_target — env var override ──────────────────────────

echo "Test: detect_merge_target — MERGE_TARGET_BRANCH env override"

repo="$TMPDIR/repo-env-override"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q
git -C "$repo" branch staging  # staging exists but env var should win

export MERGE_TARGET_BRANCH="custom-branch"
result="$(detect_merge_target "$repo")"
assert_eq "custom-branch" "$result" "returns MERGE_TARGET_BRANCH when set, even if staging exists"
unset MERGE_TARGET_BRANCH

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
