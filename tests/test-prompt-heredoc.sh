#!/usr/bin/env bash
# test-prompt-heredoc.sh — Verify prompt functions pass dynamic content via file
# references (not inline expansion) to prevent shell metacharacter expansion.
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

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

PAYLOAD='cost is $100 and $(whoami) says `pwd`'

# Stubs for globals and functions used by prompt functions
log() { :; }
_preamble() { echo "PREAMBLE"; }
MERGE_TARGET="main"
BASE_BRANCH="main"
LAST_MERGE_SHA="abc123"
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR=""
HAS_FRONTEND="false"

# Source prompt functions
source "$SRC_DIR/autopilot-prompts.sh"

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== Heredoc Expansion Tests ==="

# Test 1: prompt_finalize_fix — references file path, does not inline content
echo "Test 1: prompt_finalize_fix references file path"
test_file="$TMPDIR_TEST/test-output.txt"
printf '%s' "$PAYLOAD" > "$test_file"
output="$(prompt_finalize_fix "/tmp/repo" "$test_file" "")"
assert_contains "$output" "$test_file" "prompt_finalize_fix: contains file path"
assert_not_contains "$output" '$(whoami)' "prompt_finalize_fix: no inline expansion"

# Test 2: prompt_security_fix — references file path
echo "Test 2: prompt_security_fix references file path"
findings_file="$TMPDIR_TEST/findings.txt"
printf '%s' "$PAYLOAD" > "$findings_file"
output="$(prompt_security_fix "001" "test epic" "/tmp/repo" "feat" "$findings_file")"
assert_contains "$output" "$findings_file" "prompt_security_fix: contains file path"
assert_not_contains "$output" '$(whoami)' "prompt_security_fix: no inline expansion"

# Test 3: prompt_review_fix — references file path
echo "Test 3: prompt_review_fix references file path"
review_file="$TMPDIR_TEST/review.txt"
printf '%s' "$PAYLOAD" > "$review_file"
output="$(prompt_review_fix "cli" "001" "test epic" "/tmp/repo" "feat" "$review_file")"
assert_contains "$output" "$review_file" "prompt_review_fix: contains file path"
assert_not_contains "$output" '$(whoami)' "prompt_review_fix: no inline expansion"

# Test 4: prompt_verify_ci_fix — references both ci_file and warn_file paths
echo "Test 4: prompt_verify_ci_fix references file paths"
ci_file="$TMPDIR_TEST/ci.txt"
warn_file="$TMPDIR_TEST/warn.txt"
printf '%s' "$PAYLOAD" > "$ci_file"
printf '%s' "$PAYLOAD" > "$warn_file"
output="$(prompt_verify_ci_fix "001" "test epic" "/tmp/repo" "$ci_file" "1" "3" "$warn_file")"
assert_contains "$output" "$ci_file" "prompt_verify_ci_fix: contains ci file path"
assert_contains "$output" "$warn_file" "prompt_verify_ci_fix: contains warn file path"
assert_not_contains "$output" '$(whoami)' "prompt_verify_ci_fix: no inline expansion"

# Test 5: prompt_crystallize — references diff file, $GOPATH in file not expanded
echo "Test 5: prompt_crystallize references diff file path"
diff_file="$TMPDIR_TEST/diff.txt"
printf '%s' 'export GOPATH=$HOME/go && $GOPATH/bin/tool' > "$diff_file"
output="$(prompt_crystallize "001" "test epic" "/tmp/repo" "feat" "$diff_file")"
assert_contains "$output" "$diff_file" "prompt_crystallize: contains diff file path"
assert_not_contains "$output" '$HOME/go' "prompt_crystallize: \$HOME not expanded from file"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
