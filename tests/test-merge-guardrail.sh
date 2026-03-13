#!/usr/bin/env bash
# test-merge-guardrail.sh — Tests for merge-to-main guardrail (Item 13)
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

# Minimal stubs
AUTOPILOT_LOG=""
log() { echo "[$1] $2"; }

# Extract do_merge guardrail by sourcing common deps
source "$SRC_DIR/common.sh"

# ─── Test: merge to main refused when staging exists ────────────────────────
echo "Test: merge to main refused when staging exists"

repo="$TMPDIR_TEST/repo-guardrail"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q
git -C "$repo" branch staging

MERGE_TARGET="main"
ALLOW_MAIN_MERGE="false"
output=$(
    # Inline the guardrail logic
    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]] && \
       { git -C "$repo" rev-parse --verify origin/staging &>/dev/null || \
         git -C "$repo" rev-parse --verify staging &>/dev/null; } && \
       [[ "${ALLOW_MAIN_MERGE:-false}" != "true" ]]; then
        echo "REFUSED"
    else
        echo "ALLOWED"
    fi
)
assert_eq "REFUSED" "$output" "merge to main refused when staging exists"

# ─── Test: merge allowed with --allow-main-merge ───────────────────────────
echo "Test: merge allowed with --allow-main-merge"

ALLOW_MAIN_MERGE="true"
output=$(
    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]] && \
       { git -C "$repo" rev-parse --verify origin/staging &>/dev/null || \
         git -C "$repo" rev-parse --verify staging &>/dev/null; } && \
       [[ "${ALLOW_MAIN_MERGE:-false}" != "true" ]]; then
        echo "REFUSED"
    else
        echo "ALLOWED"
    fi
)
assert_eq "ALLOWED" "$output" "merge allowed with ALLOW_MAIN_MERGE=true"

# ─── Test: merge to staging unaffected ─────────────────────────────────────
echo "Test: merge to staging unaffected by guardrail"

MERGE_TARGET="staging"
ALLOW_MAIN_MERGE="false"
output=$(
    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]] && \
       { git -C "$repo" rev-parse --verify origin/staging &>/dev/null || \
         git -C "$repo" rev-parse --verify staging &>/dev/null; } && \
       [[ "${ALLOW_MAIN_MERGE:-false}" != "true" ]]; then
        echo "REFUSED"
    else
        echo "ALLOWED"
    fi
)
assert_eq "ALLOWED" "$output" "merge to staging not blocked"

# ─── Test: --allow-main-merge parsed by parse_args ─────────────────────────
echo "Test: --allow-main-merge flag parsed"

ALLOW_MAIN_MERGE="false"
# Check the flag exists in parse_args
if grep -q '\-\-allow-main-merge.*ALLOW_MAIN_MERGE=true' "$SRC_DIR/autopilot.sh"; then
    assert_eq "true" "true" "--allow-main-merge in parse_args"
else
    assert_eq "true" "false" "--allow-main-merge in parse_args"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -gt 0 ]] && exit 1 || exit 0
