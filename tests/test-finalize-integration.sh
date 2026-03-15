#!/usr/bin/env bash
# test-finalize-integration.sh — Integration tests for run_finalize()
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────
PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL $msg: expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        echo "  PASS $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL $msg: '$needle' not found in output"
    fi
}

# ─── Globals required before sourcing ────────────────────────────────────────
BOLD="" RESET="" GREEN="" YELLOW="" RED="" BLUE="" CYAN="" DIM=""
BASE_BRANCH="main"
MERGE_TARGET="main"
DRY_RUN=false
AUTO_REVERT_ON_FAILURE=false
LAST_MERGE_SHA=""
LAST_TEST_OUTPUT=""
LAST_LINT_OUTPUT=""
LAST_BUILD_OUTPUT=""
PROJECT_TEST_CMD=""
PROJECT_BUILD_CMD=""
PROJECT_LINT_CMD=""

# ─── Stubs (BEFORE sourcing) ────────────────────────────────────────────────
LOG_OUTPUT=""
log() { LOG_OUTPUT+="[$1] ${*:2}"$'\n'; }
sleep() { :; }
_emit_event() { :; }

# Sequenced stubs for verify_tests, verify_build, verify_lint
VERIFY_TESTS_RC_SEQ=()
VERIFY_TESTS_CALL=0
verify_tests() {
    local rc=${VERIFY_TESTS_RC_SEQ[$VERIFY_TESTS_CALL]:-0}
    VERIFY_TESTS_CALL=$((VERIFY_TESTS_CALL + 1))
    CALL_LOG+=("verify_tests")
    return "$rc"
}

VERIFY_BUILD_RC_SEQ=()
VERIFY_BUILD_CALL=0
verify_build() {
    local rc=${VERIFY_BUILD_RC_SEQ[$VERIFY_BUILD_CALL]:-0}
    VERIFY_BUILD_CALL=$((VERIFY_BUILD_CALL + 1))
    CALL_LOG+=("verify_build")
    return "$rc"
}

VERIFY_LINT_RC_SEQ=()
VERIFY_LINT_CALL=0
verify_lint() {
    local rc=${VERIFY_LINT_RC_SEQ[$VERIFY_LINT_CALL]:-0}
    VERIFY_LINT_CALL=$((VERIFY_LINT_CALL + 1))
    CALL_LOG+=("verify_lint")
    return "$rc"
}

# invoke_claude stub
INVOKE_CLAUDE_PHASES=()
INVOKE_CLAUDE_RC=0
INVOKE_CLAUDE_CALL=0
invoke_claude() {
    INVOKE_CLAUDE_PHASES+=("$1")
    INVOKE_CLAUDE_CALL=$((INVOKE_CLAUDE_CALL + 1))
    CALL_LOG+=("invoke_claude")
    return "$INVOKE_CLAUDE_RC"
}

prompt_finalize_fix() { echo "fix prompt stub"; }
prompt_finalize_review() { echo "review prompt stub"; }

WRITE_SUMMARY_CALL=0
write_project_summary() { WRITE_SUMMARY_CALL=$((WRITE_SUMMARY_CALL + 1)); }

CALL_LOG=()

# ─── Source module under test ────────────────────────────────────────────────
source "$SRC_DIR/autopilot-finalize.sh"

# ─── Helper: create tmpdir git repo ─────────────────────────────────────────
create_test_repo() {
    local repo
    repo=$(mktemp -d)
    git init -q "$repo"
    git -C "$repo" config user.email "test@test"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/file.txt"
    git -C "$repo" add -A && git -C "$repo" commit -q -m "initial"
    git -C "$repo" checkout -q -b main 2>/dev/null || true
    echo "$repo"
}

# ─── Reset helper ───────────────────────────────────────────────────────────
_reset_stubs() {
    VERIFY_TESTS_RC_SEQ=()
    VERIFY_TESTS_CALL=0
    VERIFY_BUILD_RC_SEQ=()
    VERIFY_BUILD_CALL=0
    VERIFY_LINT_RC_SEQ=()
    VERIFY_LINT_CALL=0
    INVOKE_CLAUDE_PHASES=()
    INVOKE_CLAUDE_RC=0
    INVOKE_CLAUDE_CALL=0
    WRITE_SUMMARY_CALL=0
    CALL_LOG=()
    LOG_OUTPUT=""
    DRY_RUN=false
    AUTO_REVERT_ON_FAILURE=false
    LAST_MERGE_SHA=""
    LAST_TEST_OUTPUT=""
    LAST_LINT_OUTPUT=""
    LAST_BUILD_OUTPUT=""
}

# ─── Group A: Happy Path ────────────────────────────────────────────────────
echo ""
echo "Group A: Happy Path"

# A1: All verify_* pass round 1
echo "  A1: All pass round 1"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(0)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$rc" "A1: rc=0"
# invoke_claude called 1x for finalize-review (not for fix)
assert_eq "1" "$INVOKE_CLAUDE_CALL" "A1: invoke_claude called only for review"
assert_eq "finalize-review" "${INVOKE_CLAUDE_PHASES[0]}" "A1: only call is review"
assert_eq "1" "$WRITE_SUMMARY_CALL" "A1: write_project_summary called"
rm -rf "$repo"

# A2: verify_tests fails round 1, passes round 2
echo "  A2: Tests fail round 1, pass round 2"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(1 0)
VERIFY_BUILD_RC_SEQ=(0 0)
VERIFY_LINT_RC_SEQ=(0 0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$rc" "A2: rc=0"
# 1 fix + 1 review = 2 invoke_claude calls
assert_eq "2" "$INVOKE_CLAUDE_CALL" "A2: invoke_claude called 2x (fix+review)"
assert_contains "${INVOKE_CLAUDE_PHASES[*]}" "finalize-fix" "A2: phase=finalize-fix"
rm -rf "$repo"

# A3: verify_tests fails rounds 1-2, passes round 3
echo "  A3: Tests fail rounds 1-2, pass round 3"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(1 1 0)
VERIFY_BUILD_RC_SEQ=(0 0 0)
VERIFY_LINT_RC_SEQ=(0 0 0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$rc" "A3: rc=0"
# 2 fix + 1 review = 3 invoke_claude calls
assert_eq "3" "$INVOKE_CLAUDE_CALL" "A3: invoke_claude called 3x (2 fix + review)"
rm -rf "$repo"

# ─── Group B: Exhaustion / Failure ──────────────────────────────────────────
echo ""
echo "Group B: Exhaustion / Failure"

# B1: verify_tests fails all 3 rounds
echo "  B1: Tests fail all 3 rounds"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(1 1 1)
VERIFY_BUILD_RC_SEQ=(0 0 0)
VERIFY_LINT_RC_SEQ=(0 0 0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "1" "$rc" "B1: rc=1"
# Check finalize-failure.json exists
local_failure="$repo/.specify/logs/finalize-failure.json"
if [[ -f "$local_failure" ]]; then
    reason=$(jq -r '.reason' "$local_failure")
    assert_contains "$reason" "tests_failing" "B1: reason contains tests_failing"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL B1: finalize-failure.json not found"
fi
rm -rf "$repo"

# B2: verify_build fails all 3 rounds (tests pass)
echo "  B2: Build fails all 3 rounds"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(0 0 0)
VERIFY_BUILD_RC_SEQ=(1 1 1)
VERIFY_LINT_RC_SEQ=(0 0 0)

rc=0; run_finalize "$repo" || rc=$?
# build_ok never true, loop never breaks. 3 fix + 1 review = 4
# Count only fix calls in the loop
local_fix_count=0
for p in "${INVOKE_CLAUDE_PHASES[@]}"; do
    [[ "$p" == "finalize-fix" ]] && local_fix_count=$((local_fix_count + 1))
done
assert_eq "3" "$local_fix_count" "B2: invoke_claude fix called 3x in loop"
rm -rf "$repo"

# B3: Only lint fails all 3 rounds (tests+build pass)
echo "  B3: Only lint fails all 3 rounds"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(0 0 0)
VERIFY_BUILD_RC_SEQ=(0 0 0)
VERIFY_LINT_RC_SEQ=(1 1 1)

rc=0; run_finalize "$repo" || rc=$?
# lint non-blocking: tests_ok=true so no fatal, rc=0
assert_eq "0" "$rc" "B3: rc=0 (lint non-blocking)"
assert_contains "$LOG_OUTPUT" "lint issues remain" "B3: WARN about lint"
rm -rf "$repo"

# ─── Group C: DRY_RUN ───────────────────────────────────────────────────────
echo ""
echo "Group C: DRY_RUN"

# C1: DRY_RUN=true, verify_tests returns 1
echo "  C1: DRY_RUN=true, tests fail"
_reset_stubs
repo=$(create_test_repo)
DRY_RUN=true
VERIFY_TESTS_RC_SEQ=(1 1 1)
VERIFY_BUILD_RC_SEQ=(0 0 0)
VERIFY_LINT_RC_SEQ=(0 0 0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$INVOKE_CLAUDE_CALL" "C1: invoke_claude NOT called in DRY_RUN"
rm -rf "$repo"

# C2: DRY_RUN=true, all pass
echo "  C2: DRY_RUN=true, all pass"
_reset_stubs
repo=$(create_test_repo)
DRY_RUN=true
VERIFY_TESTS_RC_SEQ=(0)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$INVOKE_CLAUDE_CALL" "C2: invoke_claude not called"
assert_eq "0" "$rc" "C2: rc=0"
rm -rf "$repo"

# ─── Group D: Cross-Epic Review ─────────────────────────────────────────────
echo ""
echo "Group D: Cross-Epic Review"

# D1: All pass in loop, review invoke succeeds, post-review verify passes
echo "  D1: Review + post-review pass"
_reset_stubs
repo=$(create_test_repo)
# Fix loop: round 1 all pass (1 call each). Post-review verify_tests: pass
VERIFY_TESTS_RC_SEQ=(0 0)  # round1=pass, post-review=pass
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$rc" "D1: rc=0"
rm -rf "$repo"

# D2: All pass in loop, review succeeds, post-review tests FAIL, refix succeeds, final pass
echo "  D2: Post-review fail, refix succeeds"
_reset_stubs
repo=$(create_test_repo)
# Fix loop: round 1 all pass. Post-review verify_tests: FAIL. Final verify_tests: PASS
VERIFY_TESTS_RC_SEQ=(0 1 0)  # round1=pass, post-review=fail, final=pass
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$rc" "D2: rc=0"
# invoke_claude: 1=finalize-review, 2=finalize-fix (refix)
assert_contains "${INVOKE_CLAUDE_PHASES[*]}" "finalize-review" "D2: finalize-review called"
assert_contains "${INVOKE_CLAUDE_PHASES[*]}" "finalize-fix" "D2: finalize-fix called"
rm -rf "$repo"

# D3: Post-review tests fail, refix fails, final verify_tests fails
echo "  D3: Post-review fail, refix fails, final verify fails"
_reset_stubs
repo=$(create_test_repo)
# Fix loop: round 1 all pass. Post-review: FAIL. Final: FAIL
VERIFY_TESTS_RC_SEQ=(0 1 1)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "1" "$rc" "D3: rc=1"
local_failure="$repo/.specify/logs/finalize-failure.json"
if [[ -f "$local_failure" ]]; then
    reason=$(jq -r '.reason' "$local_failure")
    assert_contains "$reason" "review_fix" "D3: reason contains review_fix"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL D3: finalize-failure.json not found"
fi
rm -rf "$repo"

# D4: Review invocation itself fails (invoke_claude returns 1) -> non-blocking
echo "  D4: Review invocation fails (non-blocking)"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(0 0)  # round1=pass, post-review=pass (but review fails, so post-review verify still runs? No.)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)
# invoke_claude returns 1 for review but the || catches it
INVOKE_CLAUDE_RC=1

rc=0; run_finalize "$repo" || rc=$?
# Review fails non-blocking -> post-review verify_tests runs (line 200).
# Since INVOKE_CLAUDE_RC=1, the review invoke fails. But the code does:
#   invoke_claude "finalize-review" ... || { log WARN ... }
# Then proceeds to verify_tests (post-review). verify_tests pass -> continue.
assert_eq "0" "$rc" "D4: rc=0 (review failure non-blocking)"
rm -rf "$repo"

# ─── Group E: Deferred Task Scan ────────────────────────────────────────────
echo ""
echo "Group E: Deferred Task Scan"

# E1: No deferred tasks
echo "  E1: No deferred tasks"
_reset_stubs
repo=$(create_test_repo)
mkdir -p "$repo/specs/001"
echo "- [x] completed task" > "$repo/specs/001/tasks.md"
VERIFY_TESTS_RC_SEQ=(0)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$rc" "E1: rc=0"
# No WARN about deferred tasks
if [[ "$LOG_OUTPUT" == *"deferred tasks"* ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL E1: unexpected deferred tasks WARN"
else
    PASS=$((PASS + 1))
    echo "  PASS E1: no deferred tasks WARN"
fi
rm -rf "$repo"

# E2: Has deferred tasks
echo "  E2: Has deferred tasks"
_reset_stubs
repo=$(create_test_repo)
mkdir -p "$repo/specs/001"
echo '- [-] deferred task 1
- [-] deferred task 2
- [-] deferred task 3' > "$repo/specs/001/tasks.md"
VERIFY_TESTS_RC_SEQ=(0)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "0" "$rc" "E2: rc=0"
assert_contains "$LOG_OUTPUT" "deferred tasks" "E2: WARN about deferred tasks"
rm -rf "$repo"

# ─── Group F: Auto-Revert ───────────────────────────────────────────────────
echo ""
echo "Group F: Auto-Revert"

# F1: Tests exhaust, AUTO_REVERT_ON_FAILURE=false, LAST_MERGE_SHA set
echo "  F1: No auto-revert when disabled"
_reset_stubs
repo=$(create_test_repo)
LAST_MERGE_SHA=$(git -C "$repo" rev-parse HEAD)
AUTO_REVERT_ON_FAILURE=false
VERIFY_TESTS_RC_SEQ=(1 1 1)
VERIFY_BUILD_RC_SEQ=(0 0 0)
VERIFY_LINT_RC_SEQ=(0 0 0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "1" "$rc" "F1: rc=1"
# Should NOT have done git revert — check log for "Auto-reverting"
if [[ "$LOG_OUTPUT" == *"Auto-reverting"* ]]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL F1: unexpected auto-revert"
else
    PASS=$((PASS + 1))
    echo "  PASS F1: no auto-revert attempted"
fi
rm -rf "$repo"

# F2: Tests exhaust, AUTO_REVERT_ON_FAILURE=true, real tmpdir repo
echo "  F2: Auto-revert with real git"
_reset_stubs
# Create a bare remote + clone so push works
bare_repo=$(mktemp -d)
git init -q --bare "$bare_repo"
repo=$(mktemp -d)
git clone -q "$bare_repo" "$repo"
git -C "$repo" config user.email "test@test"
git -C "$repo" config user.name "Test"
echo "initial" > "$repo/file.txt"
git -C "$repo" add -A && git -C "$repo" commit -q -m "initial"
git -C "$repo" push -q origin main 2>/dev/null || git -C "$repo" push -q -u origin HEAD:main 2>/dev/null
echo "change" > "$repo/file2.txt"
git -C "$repo" add -A && git -C "$repo" commit -q -m "merge commit"
git -C "$repo" push -q
LAST_MERGE_SHA=$(git -C "$repo" rev-parse HEAD)
AUTO_REVERT_ON_FAILURE=true
VERIFY_TESTS_RC_SEQ=(1 1 1)
VERIFY_BUILD_RC_SEQ=(0 0 0)
VERIFY_LINT_RC_SEQ=(0 0 0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "1" "$rc" "F2: rc=1"
assert_contains "$LOG_OUTPUT" "Auto-reverting" "F2: auto-revert attempted"
# Verify git log shows the revert commit
last_msg=$(git -C "$repo" log -1 --format='%s')
assert_contains "$last_msg" "Revert" "F2: revert commit exists"
rm -rf "$repo" "$bare_repo"

# F3: Tests exhaust, AUTO_REVERT_ON_FAILURE=true, LAST_MERGE_SHA=""
echo "  F3: Auto-revert no-ops with empty SHA"
_reset_stubs
repo=$(create_test_repo)
AUTO_REVERT_ON_FAILURE=true
LAST_MERGE_SHA=""
VERIFY_TESTS_RC_SEQ=(1 1 1)
VERIFY_BUILD_RC_SEQ=(0 0 0)
VERIFY_LINT_RC_SEQ=(0 0 0)

rc=0; run_finalize "$repo" || rc=$?
assert_eq "1" "$rc" "F3: rc=1"
assert_contains "$LOG_OUTPUT" "No merge SHA" "F3: no-op on empty SHA"
rm -rf "$repo"

# ─── Group G: State Restoration ─────────────────────────────────────────────
echo ""
echo "Group G: State Restoration"

# G1: finalize-failure.json has merge_sha, LAST_MERGE_SHA="" -> restored
echo "  G1: Restore merge SHA from file"
_reset_stubs
repo=$(create_test_repo)
mkdir -p "$repo/.specify/logs"
echo '{"reason":"tests_failing","merge_sha":"abc123","branch":"main","timestamp":"2025-01-01T00:00:00Z"}' \
    > "$repo/.specify/logs/finalize-failure.json"
LAST_MERGE_SHA=""
_restore_merge_sha "$repo"
assert_eq "abc123" "$LAST_MERGE_SHA" "G1: LAST_MERGE_SHA restored to abc123"
rm -rf "$repo"

# G2: LAST_MERGE_SHA already set, file has different SHA -> unchanged
echo "  G2: Existing LAST_MERGE_SHA not overwritten"
_reset_stubs
repo=$(create_test_repo)
mkdir -p "$repo/.specify/logs"
echo '{"reason":"tests_failing","merge_sha":"different_sha","branch":"main","timestamp":"2025-01-01T00:00:00Z"}' \
    > "$repo/.specify/logs/finalize-failure.json"
LAST_MERGE_SHA="existing"
_restore_merge_sha "$repo"
assert_eq "existing" "$LAST_MERGE_SHA" "G2: LAST_MERGE_SHA unchanged"
rm -rf "$repo"

# ─── Group H: Call Order & Counts ────────────────────────────────────────────
echo ""
echo "Group H: Call Order & Counts"

# H1: All pass round 1 -> CALL_LOG shows verify_tests,verify_build,verify_lint order
echo "  H1: Call order on all-pass"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(0)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
# The fix loop calls verify_tests, verify_build, verify_lint in order
assert_eq "verify_tests" "${CALL_LOG[0]}" "H1: first call is verify_tests"
assert_eq "verify_build" "${CALL_LOG[1]}" "H1: second call is verify_build"
assert_eq "verify_lint" "${CALL_LOG[2]}" "H1: third call is verify_lint"
rm -rf "$repo"

# H2: Tests fail 1 round then pass -> verify calls happen before invoke
echo "  H2: Verify before invoke on failure"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(1 0)
VERIFY_BUILD_RC_SEQ=(0 0)
VERIFY_LINT_RC_SEQ=(0 0)

rc=0; run_finalize "$repo" || rc=$?
# Round 1: verify_tests, verify_build, verify_lint, invoke_claude
assert_eq "verify_tests" "${CALL_LOG[0]}" "H2: verify_tests before invoke"
assert_eq "verify_build" "${CALL_LOG[1]}" "H2: verify_build before invoke"
assert_eq "verify_lint" "${CALL_LOG[2]}" "H2: verify_lint before invoke"
assert_eq "invoke_claude" "${CALL_LOG[3]}" "H2: invoke_claude after verifies"
rm -rf "$repo"

# H3: All pass -> write_project_summary called
echo "  H3: write_project_summary called"
_reset_stubs
repo=$(create_test_repo)
VERIFY_TESTS_RC_SEQ=(0)
VERIFY_BUILD_RC_SEQ=(0)
VERIFY_LINT_RC_SEQ=(0)

rc=0; run_finalize "$repo" || rc=$?
if [[ "$WRITE_SUMMARY_CALL" -gt 0 ]]; then
    PASS=$((PASS + 1))
    echo "  PASS H3: write_project_summary counter > 0"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL H3: write_project_summary counter = 0"
fi
rm -rf "$repo"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -gt 0 ]] && exit 1
exit 0
