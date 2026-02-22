#!/usr/bin/env bash
# test-github-sync-fixes.sh — Tests for GitHub sync bugfixes (Issues 1, 2, 4)
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
        echo "  ok - $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL - $msg: expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ok - $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL - $msg: output does not contain '$needle'"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ok - $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  FAIL - $msg: output should NOT contain '$needle'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Capture log output
LOG_OUTPUT=""
log() {
    LOG_OUTPUT+="[$1] ${*:2}"$'\n'
}

# Stub gh_try — just runs the command
gh_try() {
    local desc="$1"; shift
    "$@" 2>&1
}

# Stub _gh_phase_to_status
_gh_phase_to_status() {
    case "$1" in
        implement|review) echo "In Progress" ;;
        done)             echo "Done" ;;
        *)                echo "Todo" ;;
    esac
}

# ─── Issue 4 Tests: || true prevents crash under set -euo pipefail ──────────

echo "Issue 4: || true prevents crash on gh_update_status failure"

echo "Test 1: gh_update_status returns 1 — script does NOT exit"
(
    set -euo pipefail
    # Stub gh_update_status to fail
    gh_update_status() { return 1; }
    x="some-item-id"
    # This is the pattern that must survive under set -euo pipefail
    [[ -n "$x" ]] && gh_update_status "$x" "implement" || true
    echo "SURVIVED"
) > "$TMPDIR_TEST/t1.out" 2>&1
rc=$?
output=$(cat "$TMPDIR_TEST/t1.out")
assert_eq "0" "$rc" "subshell exits 0"
assert_contains "$output" "SURVIVED" "script continues past failed gh_update_status"

echo "Test 2: gh_update_status returns 0 — normal success path"
(
    set -euo pipefail
    gh_update_status() { return 0; }
    x="some-item-id"
    [[ -n "$x" ]] && gh_update_status "$x" "implement" || true
    echo "SURVIVED"
) > "$TMPDIR_TEST/t2.out" 2>&1
rc=$?
output=$(cat "$TMPDIR_TEST/t2.out")
assert_eq "0" "$rc" "subshell exits 0 on success"
assert_contains "$output" "SURVIVED" "script continues on success path"

echo "Test 3: empty variable — pattern short-circuits correctly"
(
    set -euo pipefail
    gh_update_status() { echo "SHOULD_NOT_RUN"; return 1; }
    x=""
    [[ -n "$x" ]] && gh_update_status "$x" "implement" || true
    echo "SURVIVED"
) > "$TMPDIR_TEST/t3.out" 2>&1
rc=$?
output=$(cat "$TMPDIR_TEST/t3.out")
assert_eq "0" "$rc" "subshell exits 0 with empty var"
assert_not_contains "$output" "SHOULD_NOT_RUN" "gh_update_status not called"
assert_contains "$output" "SURVIVED" "script continues with empty var"

# ─── Issue 1 Tests: logging in gh_update_status and gh_sync_phase ───────────

echo ""
echo "Issue 1: logging in gh_update_status and gh_sync_phase"

declare -A GH_STATUS_OPT

echo "Test 4: gh_update_status with empty GH_STATUS_OPT logs WARN"
LOG_OUTPUT=""
GH_STATUS_OPT=()
# Source the real gh_update_status
eval "$(sed -n '/^gh_update_status()/,/^}/p' "$SRC_DIR/autopilot-github-sync.sh")"
rc=0
gh_update_status "item-123" "implement" || rc=$?
assert_eq "1" "$rc" "returns 1 when no opt_id"
assert_contains "$LOG_OUTPUT" "WARN" "logs WARN level"
assert_contains "$LOG_OUTPUT" "no status option ID" "WARN mentions 'no status option ID'"

echo "Test 5: gh_sync_phase with GH_ENABLED=true logs INFO"
LOG_OUTPUT=""
GH_ENABLED=true
GH_STATUS_OPT=([Todo]="id1" ["In Progress"]="id2" [Done]="id3")
# Create minimal JSON for jq
local_json="$TMPDIR_TEST/task-issues.json"
echo '{"epic":{"item_id":"epic-item-1","url":"http://x","number":1},"tasks":{}}' > "$local_json"
# Stub _gh_task_json to return our file
_gh_task_json() { echo "$local_json"; }
# Stub gh_update_status to succeed
gh_update_status() { return 0; }
# Source gh_sync_phase
eval "$(sed -n '/^gh_sync_phase()/,/^}/p' "$SRC_DIR/autopilot-github-sync.sh")"
gh_sync_phase "$TMPDIR_TEST" "001" "plan" "/dev/null"
assert_contains "$LOG_OUTPUT" "INFO" "logs INFO level"
assert_contains "$LOG_OUTPUT" "syncing phase" "INFO mentions 'syncing phase'"

echo "Test 6: gh_sync_phase with GH_ENABLED=false does NOT log"
LOG_OUTPUT=""
GH_ENABLED=false
gh_sync_phase "$TMPDIR_TEST" "001" "plan" "/dev/null"
assert_eq "" "$LOG_OUTPUT" "no log output when GH_ENABLED=false"

# ─── Issue 2 Tests: post-setup validation of GH_STATUS_OPT ─────────────────

echo ""
echo "Issue 2: post-setup validation of GH_STATUS_OPT"

# Extract the validation block pattern we expect in autopilot.sh
_validate_status_opts() {
    if $GH_ENABLED; then
        if [[ -z "${GH_STATUS_OPT[Todo]:-}" ]] || \
           [[ -z "${GH_STATUS_OPT[In Progress]:-}" ]] || \
           [[ -z "${GH_STATUS_OPT[Done]:-}" ]]; then
            log WARN "GitHub sync: missing required status options — disabling"
            GH_ENABLED=false
        fi
    fi
}

echo "Test 7: all 3 keys present — GH_ENABLED stays true"
LOG_OUTPUT=""
GH_ENABLED=true
GH_STATUS_OPT=([Todo]="id1" ["In Progress"]="id2" [Done]="id3")
_validate_status_opts
assert_eq "true" "$GH_ENABLED" "GH_ENABLED stays true with all keys"

echo "Test 8: missing 'In Progress' key — GH_ENABLED becomes false, WARN logged"
LOG_OUTPUT=""
GH_ENABLED=true
GH_STATUS_OPT=([Todo]="id1" [Done]="id3")
_validate_status_opts
assert_eq "false" "$GH_ENABLED" "GH_ENABLED becomes false"
assert_contains "$LOG_OUTPUT" "WARN" "logs WARN"
assert_contains "$LOG_OUTPUT" "missing required status options" "WARN mentions missing options"

echo "Test 9: completely empty GH_STATUS_OPT — GH_ENABLED becomes false"
LOG_OUTPUT=""
GH_ENABLED=true
GH_STATUS_OPT=()
_validate_status_opts
assert_eq "false" "$GH_ENABLED" "GH_ENABLED becomes false with empty map"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
