#!/usr/bin/env bash
# test-error-messages.sh — Tests for improved error messages (Item 9)
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

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qF -- "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $msg: '$needle' not found in output"
    fi
}

# ─── Test: OS-specific jq install suggestion (darwin) ───────────────────────
echo "Test: OS-specific jq install message for macOS"

# Simulate the jq error path code inline
OSTYPE_SAVED="$OSTYPE"
output=$(
    OSTYPE="darwin24.6.0"
    install_cmd="sudo apt install jq"
    [[ "$OSTYPE" == darwin* ]] && install_cmd="brew install jq"
    echo "$install_cmd"
)
assert_eq "brew install jq" "$output" "macOS gets brew install jq"

# ─── Test: OS-specific jq install suggestion (linux) ───────────────────────
echo "Test: OS-specific jq install message for Linux"

output=$(
    OSTYPE="linux-gnu"
    install_cmd="sudo apt install jq"
    [[ "$OSTYPE" == darwin* ]] && install_cmd="brew install jq"
    echo "$install_cmd"
)
assert_eq "sudo apt install jq" "$output" "Linux gets sudo apt install jq"

# ─── Test: jq error code present in autopilot.sh ──────────────────────────
echo "Test: OS-aware jq error in autopilot.sh"

jq_block=$(sed -n '/Preflight: jq/,/fi/p' "$SRC_DIR/autopilot.sh" | head -7)
assert_contains "$jq_block" 'darwin' "jq preflight checks OSTYPE for darwin"
assert_contains "$jq_block" 'brew install jq' "jq preflight suggests brew on macOS"
assert_contains "$jq_block" 'sudo apt install jq' "jq preflight suggests apt on Linux"

# ─── Test: TTY guard presence in load_project_config ───────────────────────
echo "Test: TTY guard in load_project_config"

config_block=$(sed -n '/^load_project_config()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")
assert_contains "$config_block" '-t 0' "load_project_config has TTY guard [[ -t 0 ]]"
assert_contains "$config_block" 'Auto-detect project settings' "load_project_config has interactive prompt"
assert_contains "$config_block" 'autopilot-detect-project.sh' "load_project_config calls detect script"

# ─── Test: non-TTY skips interactive prompt ────────────────────────────────
echo "Test: non-TTY path exits without prompt"

# The code checks [[ -t 0 ]] — in a pipe, stdin is not a TTY
# Verify the exit 1 is still present after the interactive block
exit_after=$(sed -n '/^load_project_config()/,/^}/p' "$SRC_DIR/autopilot-lib.sh" | \
    sed -n '/\[\[ -t 0 \]\]/,/exit 1/p')
assert_contains "$exit_after" 'exit 1' "exit 1 follows TTY block (non-TTY exits)"

# ─── Test: detect_merge_target validates MERGE_TARGET_BRANCH (Item 15) ────
echo "Test: detect_merge_target validates MERGE_TARGET_BRANCH exists"

AUTOPILOT_LOG=""
log() { echo "[$1] $2" >&2; }
source "$SRC_DIR/common.sh"
eval "$(sed -n '/^detect_merge_target()/,/^}/p' "$SRC_DIR/autopilot-lib.sh")"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

repo="$TMPDIR_TEST/repo-validate-branch"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

# MERGE_TARGET_BRANCH set to non-existent branch → should fall back
BASE_BRANCH="master"
MERGE_TARGET_BRANCH="nonexistent-branch"
result=$(detect_merge_target "$repo" 2>/dev/null)
assert_eq "master" "$result" "falls back when MERGE_TARGET_BRANCH not found"

# MERGE_TARGET_BRANCH set to existing branch → should use it
git -C "$repo" branch custom-target
MERGE_TARGET_BRANCH="custom-target"
result=$(detect_merge_target "$repo" 2>/dev/null)
assert_eq "custom-target" "$result" "uses MERGE_TARGET_BRANCH when branch exists"

unset MERGE_TARGET_BRANCH

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -gt 0 ]] && exit 1 || exit 0
