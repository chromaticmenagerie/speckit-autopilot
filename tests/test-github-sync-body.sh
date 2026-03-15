#!/usr/bin/env bash
# test-github-sync-body.sh — Tests for gh_update_epic_body() in autopilot-github-sync.sh
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
        FAIL=$((FAIL + 1)); echo "  FAIL - $msg: '$needle' not found in output"
    fi
}

assert_not_contains() {
    local msg="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1)); echo "  ok - $msg"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL - $msg: '$needle' unexpectedly found in output"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Mock repo structure
REPO="$TMPDIR/repo"
mkdir -p "$REPO/.specify/logs" "$REPO/specs/003-auth"

# Mock gh on PATH
export PATH="$SCRIPT_DIR:$PATH"
export GH_MOCK_LOG="$TMPDIR/gh-calls.log"
touch "$GH_MOCK_LOG"

# ─── Stubs (before sourcing) ────────────────────────────────────────────────

LOG_OUTPUT=""
log() { LOG_OUTPUT+="[$1] ${*:2}"$'\n'; }
_emit_event() { :; }

# ─── Source modules ──────────────────────────────────────────────────────────

# autopilot-github.sh expects SCRIPT_DIR to find sync module
ORIG_SCRIPT_DIR="$SCRIPT_DIR"
SCRIPT_DIR="$SRC_DIR"
source "$SRC_DIR/autopilot-github.sh"
source "$SRC_DIR/autopilot-github-sync.sh"
SCRIPT_DIR="$ORIG_SCRIPT_DIR"

# Stub gh_try AFTER sourcing (to override the real one from autopilot-github.sh)
LAST_GH_TRY_LABEL=""
LAST_GH_TRY_BODY=""
gh_try() {
    LAST_GH_TRY_LABEL="$1"
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--body" ]]; then
            LAST_GH_TRY_BODY="$2"
            shift 2
        else
            shift
        fi
    done
    return 0
}

# ─── Globals ─────────────────────────────────────────────────────────────────

GH_ENABLED=true
GH_OWNER_REPO="testorg/test-repo"
GH_USER="testuser"
GH_PROJECT_NUM="1"
GH_OWNER="testorg"
declare -A GH_STATUS_OPT=([Todo]="opt-todo" ["In Progress"]="opt-inprog" [Done]="opt-done")

# ─── Reset helper ───────────────────────────────────────────────────────────

_reset() {
    LAST_GH_TRY_LABEL=""
    LAST_GH_TRY_BODY=""
    LOG_OUTPUT=""
    > "$GH_MOCK_LOG"
    jq -n '{epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"item1",number:1},tasks:{}}' \
        > "$REPO/.specify/logs/003-task-issues.json"
}

# ─── C1: Skips when GH_ENABLED=false ────────────────────────────────────────

echo "C1: Skips when GH_ENABLED=false"
_reset
GH_ENABLED=false
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_eq "gh_try not called" "" "$LAST_GH_TRY_LABEL"
GH_ENABLED=true

# ─── C2: Skips when tasks_file doesn't exist ────────────────────────────────

echo "C2: Skips when tasks_file doesn't exist"
_reset
gh_update_epic_body "$REPO" "003" "$TMPDIR/nonexistent.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_eq "gh_try not called" "" "$LAST_GH_TRY_LABEL"

# ─── C3: Skips when epic_url empty in JSON ──────────────────────────────────

echo "C3: Skips when epic_url empty in JSON"
_reset
echo '{"epic":null,"tasks":{}}' > "$REPO/.specify/logs/003-task-issues.json"
cat > "$REPO/specs/003-auth/tasks.md" <<'MD'
## Phase 1
- [x] Some task
MD
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_eq "gh_try not called" "" "$LAST_GH_TRY_LABEL"

# ─── C4: Single-phase body generation ───────────────────────────────────────

echo "C4: Single-phase body generation"
_reset
cat > "$REPO/specs/003-auth/tasks.md" <<'MD'
## Phase 1
- [x] Implement auth module
- [ ] Add login endpoint
MD
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_contains "body has Phase 1 header" "$LAST_GH_TRY_BODY" "## Phase 1"
assert_contains "body has checked box" "$LAST_GH_TRY_BODY" "- [x]"
assert_contains "body has unchecked box" "$LAST_GH_TRY_BODY" "- [ ]"
assert_contains "progress 1/2" "$LAST_GH_TRY_BODY" "Progress: 1/2"

# ─── C5: Multi-phase body with phase headers ────────────────────────────────

echo "C5: Multi-phase body with phase headers"
_reset
cat > "$REPO/specs/003-auth/tasks.md" <<'MD'
## Phase 1
- [x] Task A
## Phase 3
- [ ] Task B
MD
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_contains "body has Phase 1" "$LAST_GH_TRY_BODY" "## Phase 1"
assert_contains "body has Phase 3" "$LAST_GH_TRY_BODY" "## Phase 3"

# ─── C6: Deferred tasks rendered with strikethrough ─────────────────────────

echo "C6: Deferred tasks rendered with strikethrough"
_reset
cat > "$REPO/specs/003-auth/tasks.md" <<'MD'
## Phase 1
- [-] Deferred task
- [x] Done task
MD
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_contains "body has strikethrough" "$LAST_GH_TRY_BODY" "~~"
assert_contains "body has deferred marker" "$LAST_GH_TRY_BODY" "*(deferred)*"
assert_contains "body has checked task" "$LAST_GH_TRY_BODY" "- [x]"

# ─── C7: Task issue numbers linked ──────────────────────────────────────────

echo "C7: Task issue numbers linked"
_reset
jq -n '{epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"item1",number:1},tasks:{"P1.1":{url:"https://github.com/testorg/test-repo/issues/10",number:10,item_id:"item10"}}}' \
    > "$REPO/.specify/logs/003-task-issues.json"
cat > "$REPO/specs/003-auth/tasks.md" <<'MD'
## Phase 1
- [x] Implement auth module
MD
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_contains "body has issue link" "$LAST_GH_TRY_BODY" "(#10)"

# ─── C8: Progress counter accuracy ──────────────────────────────────────────

echo "C8: Progress counter accuracy"
_reset
cat > "$REPO/specs/003-auth/tasks.md" <<'MD'
## Phase 1
- [x] Done 1
- [x] Done 2
- [x] Done 3
- [ ] Open 1
- [-] Deferred 1
MD
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md"
rc=$?
assert_eq "returns 0" "0" "$rc"
assert_contains "progress 3/5" "$LAST_GH_TRY_BODY" "Progress: 3/5"

# ─── C9: gh_try failure returns 1 ───────────────────────────────────────────

echo "C9: gh_try failure returns 1"
# Save working gh_try, override with failing version
eval "$(declare -f gh_try | sed '1s/gh_try/_saved_gh_try/')"
gh_try() { return 1; }
cat > "$REPO/specs/003-auth/tasks.md" <<'MD'
## Phase 1
- [x] Task A
MD
jq -n '{epic:{url:"https://github.com/testorg/test-repo/issues/1",item_id:"item1",number:1},tasks:{}}' \
    > "$REPO/.specify/logs/003-task-issues.json"
gh_update_epic_body "$REPO" "003" "$REPO/specs/003-auth/tasks.md" || rc=$?
assert_eq "returns 1 on gh_try failure" "1" "${rc:-0}"
# Restore working gh_try
eval "$(declare -f _saved_gh_try | sed '1s/_saved_gh_try/gh_try/')"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "─── Results ───"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "Total:  $((PASS + FAIL))"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
