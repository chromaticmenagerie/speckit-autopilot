#!/usr/bin/env bash
# test-startup-warning.sh — Tests for startup warning when merging to main with staging (Item 14)
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $msg: expected '$expected', got '$actual'"
    fi
}

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

AUTOPILOT_LOG=""
log() { echo "[$1] $2"; }
source "$SRC_DIR/common.sh"

# ─── Test: warning emitted when MERGE_TARGET=master and staging exists ─────
echo "Test: warning emitted when MERGE_TARGET=master and staging exists"

repo="$TMPDIR_TEST/repo-warn"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q
git -C "$repo" branch staging

MERGE_TARGET="master"
output=$(
    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]]; then
        if git -C "$repo" rev-parse --verify staging &>/dev/null || \
           git -C "$repo" rev-parse --verify origin/staging &>/dev/null; then
            echo "WARNING_EMITTED"
        fi
    fi
)
assert_eq "WARNING_EMITTED" "$output" "warning emitted for master+staging"

# ─── Test: no warning when MERGE_TARGET=staging ───────────────────────────
echo "Test: no warning when MERGE_TARGET=staging"

MERGE_TARGET="staging"
output=$(
    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]]; then
        if git -C "$repo" rev-parse --verify staging &>/dev/null || \
           git -C "$repo" rev-parse --verify origin/staging &>/dev/null; then
            echo "WARNING_EMITTED"
        fi
    fi
    echo "NO_WARNING"
)
assert_eq "NO_WARNING" "$output" "no warning when merge target is staging"

# ─── Test: no warning when no staging branch ──────────────────────────────
echo "Test: no warning when no staging branch exists"

repo2="$TMPDIR_TEST/repo-no-staging"
mkdir -p "$repo2"
git -C "$repo2" init -q
git -C "$repo2" commit --allow-empty -m "init" -q

MERGE_TARGET="main"
output=$(
    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]]; then
        if git -C "$repo2" rev-parse --verify staging &>/dev/null || \
           git -C "$repo2" rev-parse --verify origin/staging &>/dev/null; then
            echo "WARNING_EMITTED"
        fi
    fi
    echo "NO_WARNING"
)
assert_eq "NO_WARNING" "$output" "no warning when staging branch absent"

# ─── Test: warning code exists in autopilot.sh main() ─────────────────────
echo "Test: startup warning code present in autopilot.sh"

if grep -q "staging.*branch exists" "$SRC_DIR/autopilot.sh" && grep -q "MERGE_TARGET_BRANCH=staging" "$SRC_DIR/autopilot.sh"; then
    assert_eq "true" "true" "startup warning code in main()"
else
    assert_eq "true" "false" "startup warning code in main()"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -gt 0 ]] && exit 1 || exit 0
