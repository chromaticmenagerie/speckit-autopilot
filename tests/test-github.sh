#!/usr/bin/env bash
# test-github.sh — Unit tests for autopilot-github.sh
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

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Mock repo structure
mkdir -p "$TMPDIR/repo/.specify/logs"
mkdir -p "$TMPDIR/repo/.specify/scripts/bash"
mkdir -p "$TMPDIR/repo/specs/003-auth"
mkdir -p "$TMPDIR/repo/docs/specs/epics"

# Init git repo with remote
git -C "$TMPDIR/repo" init -q
git -C "$TMPDIR/repo" remote add origin "https://github.com/testorg/test-repo.git"

# Put mock-gh on PATH
export PATH="$SCRIPT_DIR:$PATH"
export GH_MOCK_LOG="$TMPDIR/gh-calls.log"
touch "$GH_MOCK_LOG"

# Globals expected by autopilot-github.sh
REPO_ROOT="$TMPDIR/repo"
NO_GITHUB=false
BASE_BRANCH="main"

# Stub log() since autopilot-lib.sh isn't fully loaded
log() { echo "[$1] $2"; }

# Stub detect_state
detect_state() { echo "implement"; }

# Stub list_epics
list_epics() { echo "003|pending|003-auth|Auth System|$TMPDIR/repo/docs/specs/epics/epic-003.md"; }

# Stub is_epic_merged
is_epic_merged() { return 1; }

# Source the module under test (SCRIPT_DIR needed by autopilot-github.sh to find sync module)
SCRIPT_DIR="$SRC_DIR"
source "$SRC_DIR/autopilot-github.sh"

# ─── Test: _gh_phase_to_status ──────────────────────────────────────────────

echo ""
echo "=== _gh_phase_to_status ==="

assert_eq "Specify"   "$(_gh_phase_to_status specify)"         "specify → Specify"
assert_eq "Clarify"   "$(_gh_phase_to_status clarify)"         "clarify → Clarify"
assert_eq "Clarify"   "$(_gh_phase_to_status clarify-verify)"  "clarify-verify → Clarify"
assert_eq "Plan"      "$(_gh_phase_to_status plan)"            "plan → Plan"
assert_eq "Tasks"     "$(_gh_phase_to_status tasks)"           "tasks → Tasks"
assert_eq "Analyze"   "$(_gh_phase_to_status analyze)"         "analyze → Analyze"
assert_eq "Analyze"   "$(_gh_phase_to_status analyze-verify)"  "analyze-verify → Analyze"
assert_eq "Implement" "$(_gh_phase_to_status implement)"       "implement → Implement"
assert_eq "Review"    "$(_gh_phase_to_status review)"          "review → Review"
assert_eq "Review"    "$(_gh_phase_to_status finalize-fix)"    "finalize-fix → Review"
assert_eq "Review"    "$(_gh_phase_to_status finalize-review)" "finalize-review → Review"
assert_eq "Merged"    "$(_gh_phase_to_status crystallize)"     "crystallize → Merged"
assert_eq "Done"      "$(_gh_phase_to_status done)"            "done → Done"
assert_eq "Backlog"   "$(_gh_phase_to_status unknown)"         "unknown → Backlog"

# ─── Test: gh_try ───────────────────────────────────────────────────────────

echo ""
echo "=== gh_try ==="

GH_SYNC_LOG="$TMPDIR/sync.log"
GH_CONSECUTIVE_FAILS=0
GH_ENABLED=true

# Success case
output=$(gh_try "test success" echo "hello")
assert_eq "hello" "$output" "gh_try returns stdout on success"
assert_eq "0" "$GH_CONSECUTIVE_FAILS" "counter reset on success"

# Failure case
gh_try "test fail" false 2>/dev/null || true
assert_eq "1" "$GH_CONSECUTIVE_FAILS" "counter increments on failure"

gh_try "test fail 2" false 2>/dev/null || true
assert_eq "2" "$GH_CONSECUTIVE_FAILS" "counter at 2 after second failure"

# Success resets
gh_try "test reset" echo "ok" >/dev/null
assert_eq "0" "$GH_CONSECUTIVE_FAILS" "counter resets after success"

# ─── Test: gh_detect ────────────────────────────────────────────────────────

echo ""
echo "=== gh_detect ==="

GH_ENABLED=false
NO_GITHUB=false
gh_detect
assert_eq "true" "$GH_ENABLED" "gh_detect enables with mock gh"
assert_eq "testuser" "$GH_USER" "gh_detect captures username"

# --no-github flag
GH_ENABLED=false
NO_GITHUB=true
gh_detect
assert_eq "false" "$GH_ENABLED" "gh_detect respects --no-github"
NO_GITHUB=false

# ─── Test: tasks.md parsing via gh_create_task_issues ────────────────────────

echo ""
echo "=== gh_create_task_issues ==="

# Reset state
GH_ENABLED=true
GH_OWNER="testorg"
GH_OWNER_REPO="testorg/test-repo"
GH_PROJECT_NUM="1"
GH_PROJECT_NODE_ID="PVT_test123"
GH_USER="testuser"

# Create sample tasks.md
cat > "$TMPDIR/repo/specs/003-auth/tasks.md" << 'EOF'
## Phase 1
- [ ] Set up auth module scaffolding
- [x] Define User model and migrations
- [ ] Add password hashing [P]

## Phase 2
- [ ] Build login endpoint
- [ ] Build registration endpoint

<!-- ANALYZED -->
EOF

# Init JSON file
echo '{"epic":{"url":"https://github.com/testorg/test-repo/issues/10","item_id":"PVTI_epic","number":10},"tasks":{}}' \
    > "$TMPDIR/repo/.specify/logs/003-task-issues.json"

# Clear mock log
> "$GH_MOCK_LOG"

# Run
gh_create_task_issues "$TMPDIR/repo" "003" "$TMPDIR/repo/specs/003-auth/tasks.md"

# Check that issues were created (5 tasks)
issue_creates=$(grep -c "issue create" "$GH_MOCK_LOG" || true)
assert_eq "5" "$issue_creates" "5 task issues created"

# Check that items were added to project
item_adds=$(grep -c "project item-add" "$GH_MOCK_LOG" || true)
assert_eq "5" "$item_adds" "5 items added to project"

# Check JSON was populated
task_count=$(jq '.tasks | length' "$TMPDIR/repo/.specify/logs/003-task-issues.json")
assert_eq "5" "$task_count" "5 tasks in JSON mapping"

# Check specific task keys
p11=$(jq -r '.tasks["P1.1"].title // empty' "$TMPDIR/repo/.specify/logs/003-task-issues.json")
assert_contains "$p11" "003-P1.1" "P1.1 key has correct title prefix"

p13=$(jq -r '.tasks["P1.3"].title // empty' "$TMPDIR/repo/.specify/logs/003-task-issues.json")
# Should NOT contain [P] marker
if [[ "$p13" == *"[P]"* ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ P1.3 title should not contain [P] marker"
else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ P1.3 title stripped [P] marker"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════"
echo "Tests: $TESTS_RUN | Passed: $TESTS_PASSED | Failed: $TESTS_FAILED"
echo "═══════════════════════════════════════"

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
