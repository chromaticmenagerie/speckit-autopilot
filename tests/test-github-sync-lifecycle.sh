#!/usr/bin/env bash
# test-github-sync-lifecycle.sh — Tests for gh_sync_done and gh_resync
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────

PASS=0
FAIL=0

assert_eq() {
    local msg="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1)); echo "  ok - $msg"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL - $msg: expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local msg="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1)); echo "  ok - $msg"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL - $msg: '$needle' not found"
    fi
}

assert_not_contains() {
    local msg="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1)); echo "  ok - $msg"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL - $msg: '$needle' unexpectedly found"
    fi
}

_count_matches() {
    echo "$1" | grep -c "$2" 2>/dev/null || echo "0"
}

# ─── Temp dir ──────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ─── Stubs (defined BEFORE sourcing) ──────────────────────────────────────

LOG_OUTPUT=""
log() { LOG_OUTPUT+="[$1] ${*:2}"$'\n'; }
_emit_event() { :; }

# Resync stubs (defined before sourcing)
_LIST_EPICS_OUTPUT=""
list_epics() { echo "$_LIST_EPICS_OUTPUT"; }

_DETECT_STATE_RESULT="implement"
detect_state() { echo "$_DETECT_STATE_RESULT"; }

_IS_EPIC_MERGED_RC=1
is_epic_merged() { return "$_IS_EPIC_MERGED_RC"; }

# ─── Global Variables ──────────────────────────────────────────────────────

GH_ENABLED=true
GH_OWNER_REPO="testorg/test-repo"
GH_USER="testuser"
GH_PROJECT_NUM="1"
GH_OWNER="testorg"
GH_PROJECT_NODE_ID="PVT_test123"
GH_FIELD_STATUS_ID="field-status-id"
GH_CONSECUTIVE_FAILS=0
GH_SYNC_LOG="$TMPDIR/gh-sync.log"
touch "$GH_SYNC_LOG"
declare -A GH_STATUS_OPT=([Todo]="opt-todo" ["In Progress"]="opt-inprog" [Done]="opt-done")

# ─── Source Modules ────────────────────────────────────────────────────────

# autopilot-github.sh uses SCRIPT_DIR to find sync module
ORIG_SCRIPT_DIR="$SCRIPT_DIR"
SCRIPT_DIR="$SRC_DIR"
source "$SRC_DIR/autopilot-github.sh"
source "$SRC_DIR/autopilot-github-sync.sh"
SCRIPT_DIR="$ORIG_SCRIPT_DIR"

# ─── Mock gh (AFTER sourcing, so it overrides PATH-based gh) ─────────────
# Use a file for call tracking (subshells in gh_try lose variable state)

GH_CALLS_FILE="$TMPDIR/gh-calls.log"
touch "$GH_CALLS_FILE"
GH_ISSUE_VIEW_LABELS=""

gh() {
    echo "$*" >> "$GH_CALLS_FILE"
    case "$*" in
        *"issue view"*"--json labels"*)
            echo "${GH_ISSUE_VIEW_LABELS:-}"
            ;;
        *"issue create"*)
            echo "https://github.com/testorg/test-repo/issues/99"
            ;;
        *"issue close"*)
            return 0
            ;;
        *"issue edit"*)
            return 0
            ;;
        *"project item-add"*)
            echo '{"id":"item-new"}'
            ;;
        *"project item-edit"*)
            return 0
            ;;
        *"label create"*)
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Override gh_try AFTER sourcing to use our mock gh function
gh_try() {
    local desc="$1"; shift
    local output rc=0
    output=$("$@" 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then return 1; fi
    echo "$output"
}

# ─── Fixtures ──────────────────────────────────────────────────────────────

REPO="$TMPDIR/repo"
mkdir -p "$REPO/.specify/logs" "$REPO/specs/003-auth"

# ─── Reset Helper ──────────────────────────────────────────────────────────

_reset() {
    : > "$GH_CALLS_FILE"
    LOG_OUTPUT=""
    GH_ENABLED=true
    GH_ISSUE_VIEW_LABELS=""
}

_gh_call_count() {
    grep -c "$1" "$GH_CALLS_FILE" 2>/dev/null || true
}

_gh_calls_contain() {
    grep -q "$1" "$GH_CALLS_FILE" 2>/dev/null
}

_gh_calls_content() {
    cat "$GH_CALLS_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== gh_sync_done tests ==="
# ═══════════════════════════════════════════════════════════════════════════

# D1: Skips when GH_ENABLED=false
echo "D1: Skips when GH_ENABLED=false"
_reset
GH_ENABLED=false
gh_sync_done "$REPO" "003"
rc=$?
assert_eq "D1 rc=0" "0" "$rc"
call_count=$(_gh_call_count ".")
assert_eq "D1 no gh calls" "0" "${call_count:-0}"

# D2: Happy path — closes all tasks + epic
echo "D2: Happy path — closes all tasks + epic"
_reset
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{
    "P1.1":{url:"https://github.com/testorg/test-repo/issues/2",item_id:"task-item-1",number:2},
    "P1.2":{url:"https://github.com/testorg/test-repo/issues/3",item_id:"task-item-2",number:3}
  }
}' > "$REPO/.specify/logs/003-task-issues.json"
GH_ISSUE_VIEW_LABELS=""
gh_sync_done "$REPO" "003"
view_count=$(_gh_call_count "issue view")
assert_eq "D2 issue view called 2x" "2" "${view_count:-0}"
close_count=$(_gh_call_count "issue close")
assert_eq "D2 issue close called 3x (2 tasks + epic)" "3" "${close_count:-0}"
assert_contains "D2 logs done" "$LOG_OUTPUT" "synced as Done"

# D3: Skip-findings label prevents task close
echo "D3: Skip-findings label prevents task close"
_reset
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{
    "P1.1":{url:"https://github.com/testorg/test-repo/issues/2",item_id:"task-item-1",number:2},
    "P1.2":{url:"https://github.com/testorg/test-repo/issues/3",item_id:"task-item-2",number:3}
  }
}' > "$REPO/.specify/logs/003-task-issues.json"
GH_ISSUE_VIEW_LABELS="autopilot:skipped-findings"
gh_sync_done "$REPO" "003"
assert_contains "D3 logs skip" "$LOG_OUTPUT" "Skipping close for skip-findings"
# Only epic close, no task closes
epic_close_count=$(_gh_call_count "issue close")
assert_eq "D3 epic still closed" "1" "${epic_close_count:-0}"

# D4: Task URL empty → skip issue view/close, still update status
echo "D4: Task URL empty → skip view/close, still update status"
_reset
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{"P1.1":{item_id:"task-item-1",number:2}}
}' > "$REPO/.specify/logs/003-task-issues.json"
gh_sync_done "$REPO" "003"
view_count=$(_gh_call_count "issue view")
assert_eq "D4 no issue view" "0" "${view_count:-0}"
edit_count=$(_gh_call_count "project item-edit")
assert_eq "D4 project item-edit called" "1" "$([[ ${edit_count:-0} -ge 1 ]] && echo 1 || echo 0)"

# D5: Task item_id empty → skip status update
echo "D5: Task item_id empty → skip status update"
_reset
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{"P1.1":{url:"https://github.com/testorg/test-repo/issues/2",number:2}}
}' > "$REPO/.specify/logs/003-task-issues.json"
GH_ISSUE_VIEW_LABELS=""
gh_sync_done "$REPO" "003"
close_count=$(_gh_call_count "issue close")
assert_eq "D5 issue close called" "1" "$([[ ${close_count:-0} -ge 1 ]] && echo 1 || echo 0)"
# item-edit should only be for epic (epic-item), not for the task
item_edit_count=$(_gh_call_count "project item-edit")
assert_eq "D5 only epic status update" "1" "${item_edit_count:-0}"

# D6: Optional tasks_file — present
echo "D6: Optional tasks_file — present"
_reset
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{}
}' > "$REPO/.specify/logs/003-task-issues.json"
echo "## Phase 1" > "$REPO/specs/003-auth/tasks.md"
gh_sync_done "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
edit_count=$(_gh_call_count "issue edit")
assert_eq "D6 issue edit called" "1" "$([[ ${edit_count:-0} -ge 1 ]] && echo 1 || echo 0)"

# D7: Optional tasks_file — omitted
echo "D7: Optional tasks_file — omitted"
_reset
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{}
}' > "$REPO/.specify/logs/003-task-issues.json"
gh_sync_done "$REPO" "003"
edit_count=$(_gh_call_count "issue edit")
assert_eq "D7 no issue edit" "0" "${edit_count:-0}"

# D8: Epic URL empty → skip epic close
echo "D8: Epic URL empty → skip epic close"
_reset
jq -n '{epic:{item_id:"epic-item"},tasks:{}}' > "$REPO/.specify/logs/003-task-issues.json"
gh_sync_done "$REPO" "003"
close_count=$(_gh_call_count "issue close")
assert_eq "D8 no issue close" "0" "${close_count:-0}"

# D9: All operations fail → still returns 0
echo "D9: All operations fail → still returns 0"
_reset
# Save original gh and override with failing version
eval "$(declare -f gh | sed '1s/gh/_gh_orig/')"
gh() { echo "$*" >> "$GH_CALLS_FILE"; return 1; }
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{"P1.1":{url:"https://github.com/testorg/test-repo/issues/2",item_id:"task-item-1",number:2}}
}' > "$REPO/.specify/logs/003-task-issues.json"
GH_ISSUE_VIEW_LABELS=""
rc=0
gh_sync_done "$REPO" "003" || rc=$?
assert_eq "D9 rc=0 despite failures" "0" "$rc"
assert_contains "D9 logs done" "$LOG_OUTPUT" "synced as Done"
# Restore original gh
eval "$(declare -f _gh_orig | sed '1s/_gh_orig/gh/')"

# D10: Logs OK on completion
echo "D10: Logs OK on completion"
_reset
jq -n '{
  epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"epic-item",number:1},
  tasks:{}
}' > "$REPO/.specify/logs/003-task-issues.json"
gh_sync_done "$REPO" "003"
assert_contains "D10 logs OK" "$LOG_OUTPUT" "synced as Done"

# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== gh_resync tests ==="
# ═══════════════════════════════════════════════════════════════════════════

# Override sub-functions with tracking stubs for resync tests
_CREATE_EPIC_CALLS=0
_CREATE_TASKS_CALLS=0
_SYNC_PHASE_CALLS=0
_SYNC_DONE_CALLS=0
_SYNC_DONE_RC=0

_setup_resync_stubs() {
    _reset
    _CREATE_EPIC_CALLS=0
    _CREATE_TASKS_CALLS=0
    _SYNC_PHASE_CALLS=0
    _SYNC_DONE_CALLS=0
    _SYNC_DONE_RC=0
    _LIST_EPICS_OUTPUT=""
    _DETECT_STATE_RESULT="implement"
    _IS_EPIC_MERGED_RC=1

    gh_create_epic_issue() { _CREATE_EPIC_CALLS=$((_CREATE_EPIC_CALLS + 1)); }
    gh_create_task_issues() { _CREATE_TASKS_CALLS=$((_CREATE_TASKS_CALLS + 1)); }
    gh_sync_phase() { _SYNC_PHASE_CALLS=$((_SYNC_PHASE_CALLS + 1)); }
    gh_sync_done() { _SYNC_DONE_CALLS=$((_SYNC_DONE_CALLS + 1)); return "$_SYNC_DONE_RC"; }
}

# E1: Empty epic list → logs 0 epics
echo "E1: Empty epic list → logs 0 epics"
_setup_resync_stubs
_LIST_EPICS_OUTPUT=""
gh_resync "$REPO"
assert_contains "E1 0 epics" "$LOG_OUTPUT" "0 epics, 0 with tasks"

# E2: Single epic, no tasks.md
echo "E2: Single epic, no tasks.md"
_setup_resync_stubs
_LIST_EPICS_OUTPUT='003|open|003-auth|Auth System|docs/specs/epics/epic-003-auth.md'
rm -f "$REPO/specs/003-auth/tasks.md"
_DETECT_STATE_RESULT="implement"
_IS_EPIC_MERGED_RC=1
gh_resync "$REPO"
assert_eq "E2 create epic called" "1" "$_CREATE_EPIC_CALLS"
assert_eq "E2 create tasks not called" "0" "$_CREATE_TASKS_CALLS"
assert_contains "E2 1 epic 0 tasks" "$LOG_OUTPUT" "1 epics, 0 with tasks"

# E3: Single epic, with tasks.md
echo "E3: Single epic, with tasks.md"
_setup_resync_stubs
_LIST_EPICS_OUTPUT='003|open|003-auth|Auth System|docs/specs/epics/epic-003-auth.md'
echo "## Phase 1" > "$REPO/specs/003-auth/tasks.md"
_DETECT_STATE_RESULT="implement"
_IS_EPIC_MERGED_RC=1
gh_resync "$REPO"
assert_eq "E3 create epic called" "1" "$_CREATE_EPIC_CALLS"
assert_eq "E3 create tasks called" "1" "$_CREATE_TASKS_CALLS"
assert_contains "E3 1 epic 1 tasks" "$LOG_OUTPUT" "1 epics, 1 with tasks"

# E4: Done epic triggers gh_sync_done
echo "E4: Done epic triggers gh_sync_done"
_setup_resync_stubs
_LIST_EPICS_OUTPUT='003|open|003-auth|Auth System|docs/specs/epics/epic-003-auth.md'
_DETECT_STATE_RESULT="done"
rm -f "$REPO/specs/003-auth/tasks.md"
gh_resync "$REPO"
assert_eq "E4 sync_done called" "1" "$_SYNC_DONE_CALLS"

# E5: Merged epic triggers gh_sync_done
echo "E5: Merged epic triggers gh_sync_done"
_setup_resync_stubs
_LIST_EPICS_OUTPUT='003|merged|003-auth|Auth System|docs/specs/epics/epic-003-auth.md'
_DETECT_STATE_RESULT="implement"
_IS_EPIC_MERGED_RC=0
rm -f "$REPO/specs/003-auth/tasks.md"
gh_resync "$REPO"
assert_eq "E5 sync_done called" "1" "$_SYNC_DONE_CALLS"

# E6: Non-done/non-merged epic skips gh_sync_done
echo "E6: Non-done/non-merged epic skips gh_sync_done"
_setup_resync_stubs
_LIST_EPICS_OUTPUT='003|open|003-auth|Auth System|docs/specs/epics/epic-003-auth.md'
_DETECT_STATE_RESULT="implement"
_IS_EPIC_MERGED_RC=1
rm -f "$REPO/specs/003-auth/tasks.md"
gh_resync "$REPO"
assert_eq "E6 sync_done not called" "0" "$_SYNC_DONE_CALLS"

# E7: gh_sync_done failure → warns + continues
echo "E7: gh_sync_done failure → warns + continues"
_setup_resync_stubs
_SYNC_DONE_RC=1
_LIST_EPICS_OUTPUT='003|open|003-auth|Auth System|docs/specs/epics/epic-003-auth.md
004|open|004-api|API System|docs/specs/epics/epic-004-api.md'
mkdir -p "$REPO/specs/004-api"
rm -f "$REPO/specs/003-auth/tasks.md" "$REPO/specs/004-api/tasks.md"
_DETECT_STATE_RESULT="done"
gh_resync "$REPO"
assert_contains "E7 warns on failure" "$LOG_OUTPUT" "WARN"
assert_contains "E7 both processed" "$LOG_OUTPUT" "2 epics"

# E8: Multiple epics processed
echo "E8: Multiple epics processed"
_setup_resync_stubs
_LIST_EPICS_OUTPUT='001|open|001-setup|Setup|e1.md
002|open|002-core|Core|e2.md
003|open|003-auth|Auth|e3.md'
mkdir -p "$REPO/specs/001-setup" "$REPO/specs/002-core"
rm -f "$REPO/specs/001-setup/tasks.md" "$REPO/specs/002-core/tasks.md" "$REPO/specs/003-auth/tasks.md"
_DETECT_STATE_RESULT="implement"
_IS_EPIC_MERGED_RC=1
gh_resync "$REPO"
assert_eq "E8 create epic 3x" "3" "$_CREATE_EPIC_CALLS"
assert_eq "E8 sync phase 3x" "3" "$_SYNC_PHASE_CALLS"
assert_contains "E8 3 epics" "$LOG_OUTPUT" "3 epics"

# ─── Summary ──────────────────────────────────────────────────────────────

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "TOTAL: $((PASS + FAIL))"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
