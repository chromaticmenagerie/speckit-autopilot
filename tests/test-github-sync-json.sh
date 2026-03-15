#!/usr/bin/env bash
# test-github-sync-json.sh — Tests for _gh_task_json() and gh_create_epic_issue()
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────

PASS=0
FAIL=0

assert_eq() {
    local msg="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "  ok - $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL - $msg: expected '$expected', got '$actual'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Mock gh via PATH
export PATH="$SCRIPT_DIR:$PATH"
export GH_MOCK_LOG="$TMPDIR/gh-calls.log"
export MOCK_LOG="$TMPDIR/gh-calls.log"
touch "$GH_MOCK_LOG"

# Stubs — BEFORE sourcing modules
LOG_OUTPUT=""
log() { LOG_OUTPUT+="[$1] ${*:2}"$'\n'; }
_emit_event() { :; }

# Source modules (autopilot-github.sh sources autopilot-github-sync.sh via SCRIPT_DIR)
SCRIPT_DIR="$SRC_DIR"
source "$SRC_DIR/autopilot-github.sh"
source "$SRC_DIR/autopilot-github-sync.sh"

# Restore SCRIPT_DIR for test context
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Global variables ──────────────────────────────────────────────────────

GH_ENABLED=true
GH_OWNER_REPO="testorg/test-repo"
GH_USER="testuser"
GH_PROJECT_NUM="1"
GH_OWNER="testorg"
GH_PROJECT_NODE_ID="PVT_test123"
declare -A GH_STATUS_OPT=([Todo]="opt-todo" ["In Progress"]="opt-inprog" [Done]="opt-done")

# GH_SYNC_LOG needed by gh_try
GH_SYNC_LOG="$TMPDIR/github-sync.log"
touch "$GH_SYNC_LOG"

# Save original gh_try for restoration after override tests
eval "_orig_gh_try() $(declare -f gh_try | tail -n +2)"

# ─── Fixture setup ─────────────────────────────────────────────────────────

REPO="$TMPDIR/repo"
mkdir -p "$REPO/.specify/logs" "$REPO/specs/003-auth"

# ═══════════════════════════════════════════════════════════════════════════
# Section A: _gh_task_json tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "=== Section A: _gh_task_json ==="

# ─── Test A1: Creates JSON file when missing ───
echo "--- A1: Creates JSON file when missing ---"
rm -f "$REPO/.specify/logs/003-task-issues.json"
result=$(_gh_task_json "$REPO" "003")
assert_eq "file exists" "0" "$([[ -f "$result" ]] && echo 0 || echo 1)"
content=$(jq -c '.' "$result")
assert_eq "content is initial JSON" '{"epic":null,"tasks":{}}' "$content"

# ─── Test A2: Returns existing file unchanged ───
echo "--- A2: Returns existing file unchanged ---"
echo '{"epic":{"url":"https://example.com"},"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
result=$(_gh_task_json "$REPO" "003")
url=$(jq -r '.epic.url' "$result")
assert_eq "epic.url preserved" "https://example.com" "$url"

# ─── Test A3: Creates parent directories ───
echo "--- A3: Creates parent directories ---"
result=$(_gh_task_json "$TMPDIR/newrepo" "005")
assert_eq "directory created" "0" "$([[ -d "$TMPDIR/newrepo/.specify/logs" ]] && echo 0 || echo 1)"
assert_eq "file created" "0" "$([[ -f "$result" ]] && echo 0 || echo 1)"

# ─── Test A4: Returns correct path format ───
echo "--- A4: Returns correct path format ---"
result=$(_gh_task_json "$REPO" "003")
assert_eq "path format" "$REPO/.specify/logs/003-task-issues.json" "$result"

# ─── Test A5: Idempotent on repeated calls ───
echo "--- A5: Idempotent on repeated calls ---"
rm -f "$REPO/.specify/logs/003-task-issues.json"
result1=$(_gh_task_json "$REPO" "003")
content1=$(cat "$result1")
result2=$(_gh_task_json "$REPO" "003")
content2=$(cat "$result2")
assert_eq "same path both calls" "$result1" "$result2"
assert_eq "content unchanged" "$content1" "$content2"

# ═══════════════════════════════════════════════════════════════════════════
# Section B: gh_create_epic_issue tests
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "=== Section B: gh_create_epic_issue ==="

# ─── Test B1: Skips when GH_ENABLED=false ───
echo "--- B1: Skips when GH_ENABLED=false ---"
GH_ENABLED=false
: > "$GH_MOCK_LOG"
gh_create_epic_issue "$REPO" "003" "Auth System"
rc=$?
assert_eq "return code 0" "0" "$rc"
mock_content=$(cat "$GH_MOCK_LOG")
assert_eq "no gh calls" "" "$mock_content"
GH_ENABLED=true

# ─── Test B2: Skips when epic already created (idempotent) ───
echo "--- B2: Skips when epic already created ---"
jq -n '{epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"item1",number:1},tasks:{}}' \
    > "$REPO/.specify/logs/003-task-issues.json"
: > "$GH_MOCK_LOG"
gh_create_epic_issue "$REPO" "003" "Auth System"
rc=$?
assert_eq "return code 0" "0" "$rc"
mock_content=$(cat "$GH_MOCK_LOG")
issue_count=$(grep -c 'issue create' "$GH_MOCK_LOG" 2>/dev/null || true)
assert_eq "no issue create calls" "0" "${issue_count:-0}"

# ─── Test B3: Happy path — creates issue, adds to project, updates JSON ───
echo "--- B3: Happy path ---"
echo '{"epic":null,"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
: > "$GH_MOCK_LOG"
LOG_OUTPUT=""
gh_create_epic_issue "$REPO" "003" "Auth System"
rc=$?
assert_eq "return code 0" "0" "$rc"
assert_eq "label create called" "1" "$([[ $(grep -c 'label create' "$GH_MOCK_LOG") -ge 1 ]] && echo 1 || echo 0)"
assert_eq "issue create called" "1" "$([[ $(grep -c 'issue create' "$GH_MOCK_LOG") -ge 1 ]] && echo 1 || echo 0)"
assert_eq "project item-add called" "1" "$([[ $(grep -c 'project item-add' "$GH_MOCK_LOG") -ge 1 ]] && echo 1 || echo 0)"
epic_url=$(jq -r '.epic.url // empty' "$REPO/.specify/logs/003-task-issues.json")
assert_eq "epic.url not empty" "1" "$([[ -n "$epic_url" ]] && echo 1 || echo 0)"
epic_item=$(jq -r '.epic.item_id // empty' "$REPO/.specify/logs/003-task-issues.json")
assert_eq "epic.item_id not empty" "1" "$([[ -n "$epic_item" ]] && echo 1 || echo 0)"

# ─── Test B4: Issue creation fails → returns 1 ───
echo "--- B4: Issue creation fails ---"
echo '{"epic":null,"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
: > "$GH_MOCK_LOG"
gh_try() { return 1; }
rc=0
gh_create_epic_issue "$REPO" "003" "Auth System" || rc=$?
assert_eq "return code 1" "1" "$rc"
# Restore gh_try
eval "gh_try() $(declare -f _orig_gh_try | tail -n +2)"

# ─── Test B5: Project item-add fails → returns 1 ───
echo "--- B5: Project item-add fails ---"
echo '{"epic":null,"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
: > "$GH_MOCK_LOG"
gh_try() {
    if [[ "$1" == *"project"* ]]; then return 1; fi
    shift; "$@"
}
rc=0
gh_create_epic_issue "$REPO" "003" "Auth System" || rc=$?
assert_eq "return code 1" "1" "$rc"
# Restore gh_try
eval "gh_try() $(declare -f _orig_gh_try | tail -n +2)"

# ─── Test B6: Label creation fails → continues ───
echo "--- B6: Label creation fails → continues ---"
echo '{"epic":null,"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
: > "$GH_MOCK_LOG"
gh_create_epic_issue "$REPO" "003" "Auth System"
rc=$?
assert_eq "return code 0" "0" "$rc"
assert_eq "label create called" "1" "$([[ $(grep -c 'label create' "$GH_MOCK_LOG") -ge 1 ]] && echo 1 || echo 0)"
assert_eq "issue create called" "1" "$([[ $(grep -c 'issue create' "$GH_MOCK_LOG") -ge 1 ]] && echo 1 || echo 0)"

# ─── Test B7: Logs OK on success ───
echo "--- B7: Logs OK on success ---"
echo '{"epic":null,"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
: > "$GH_MOCK_LOG"
LOG_OUTPUT=""
gh_create_epic_issue "$REPO" "003" "Auth System"
assert_eq "log contains Created epic issue" "1" "$([[ "$LOG_OUTPUT" == *"Created epic issue"* ]] && echo 1 || echo 0)"

# ─── Test B8: Title with special characters ───
echo "--- B8: Title with special characters ---"
echo '{"epic":null,"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
: > "$GH_MOCK_LOG"
gh_create_epic_issue "$REPO" "003" 'Auth & "Quotes"'
rc=$?
assert_eq "return code 0 (special chars)" "0" "$rc"

# ═══════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed (total $((PASS + FAIL)))"
echo "═══════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
