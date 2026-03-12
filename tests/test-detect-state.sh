#!/usr/bin/env bash
# test-detect-state.sh — Verify detect_state() returns clean values (no log contamination)
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
        echo "  ✗ $msg: '$haystack' does not contain '$needle'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Source the library (log() now writes to stderr, so it won't contaminate stdout)
AUTOPILOT_LOG=""
BASE_BRANCH="master"
source "$SRC_DIR/autopilot-lib.sh"

# Stub find_pen_file and is_epic_merged (not relevant for these tests)
find_pen_file() { echo ""; }
is_epic_merged() { return 1; }

# ─── Test: prefix mismatch returns clean "specify" ──────────────────────────

echo "Test: prefix mismatch returns clean 'specify' on stdout"

repo="$TMPDIR/repo-mismatch"
mkdir -p "$repo/specs/001-wrong-name"
echo "# spec" > "$repo/specs/001-wrong-name/spec.md"
git -C "$repo" init -q
git -C "$repo" commit --allow-empty -m "init" -q

state=$(detect_state "$repo" "003" "001-wrong-name" 2>/dev/null)
assert_eq "specify" "$state" "stdout is exactly 'specify'"

# ─── Test: prefix mismatch logs warning to stderr ───────────────────────────

echo "Test: prefix mismatch logs warning to stderr"

state=$(detect_state "$repo" "003" "001-wrong-name" 2>"$TMPDIR/stderr")
stderr_output=$(cat "$TMPDIR/stderr")
assert_eq "specify" "$state" "stdout still clean 'specify'"
assert_contains "$stderr_output" "doesn't match" "stderr contains warning about mismatch"

# ─── Test: matching prefix returns correct state ────────────────────────────

echo "Test: matching prefix returns correct state (not 'specify')"

repo2="$TMPDIR/repo-match"
mkdir -p "$repo2/specs/003-my-feature"
echo "# spec" > "$repo2/specs/003-my-feature/spec.md"
git -C "$repo2" init -q
git -C "$repo2" commit --allow-empty -m "init" -q

state=$(detect_state "$repo2" "003" "003-my-feature" 2>/dev/null)
# Should advance past specify since spec.md exists — expect "clarify"
assert_eq "clarify" "$state" "correct prefix advances past specify"

# ─── Test: empty short_name returns "specify" ───────────────────────────────

echo "Test: empty short_name returns 'specify'"

state=$(detect_state "$repo2" "003" "" 2>/dev/null)
assert_eq "specify" "$state" "empty short_name returns specify"

# ─── Test: all tasks complete, no security/requirements markers → "verify-requirements" ─

echo "Test: all tasks complete, no security/requirements markers returns 'verify-requirements'"

repo3="$TMPDIR/repo-security"
mkdir -p "$repo3/specs/003-secure-feat"
echo "# spec" > "$repo3/specs/003-secure-feat/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo3/specs/003-secure-feat/spec.md"
echo "# plan" > "$repo3/specs/003-secure-feat/plan.md"
cat > "$repo3/specs/003-secure-feat/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
TASKS
git -C "$repo3" init -q
git -C "$repo3" commit --allow-empty -m "init" -q

state=$(detect_state "$repo3" "003" "003-secure-feat" 2>/dev/null)
assert_eq "verify-requirements" "$state" "all tasks complete, no requirements/security markers → verify-requirements"

# ─── Test: all tasks complete, all markers present → "review" ─────────

echo "Test: all tasks complete, all markers present returns 'review'"

repo4="$TMPDIR/repo-security-done"
mkdir -p "$repo4/specs/003-secure-done"
echo "# spec" > "$repo4/specs/003-secure-done/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo4/specs/003-secure-done/spec.md"
echo "# plan" > "$repo4/specs/003-secure-done/plan.md"
cat > "$repo4/specs/003-secure-done/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_VERIFIED -->
<!-- SECURITY_REVIEWED -->
<!-- VERIFY_CI_COMPLETE -->
TASKS
git -C "$repo4" init -q
git -C "$repo4" commit --allow-empty -m "init" -q

state=$(detect_state "$repo4" "003" "003-secure-done" 2>/dev/null)
assert_eq "review" "$state" "all tasks complete, all markers present → review"

# ─── Test: all tasks complete, force-skipped marker → "review" ────────────

echo "Test: all tasks complete, force-skipped marker returns 'review'"

repo5="$TMPDIR/repo-security-skipped"
mkdir -p "$repo5/specs/003-secure-skip"
echo "# spec" > "$repo5/specs/003-secure-skip/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo5/specs/003-secure-skip/spec.md"
echo "# plan" > "$repo5/specs/003-secure-skip/plan.md"
cat > "$repo5/specs/003-secure-skip/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_VERIFIED -->
<!-- SECURITY_REVIEWED -->
<!-- SECURITY_FORCE_SKIPPED -->
<!-- VERIFY_CI_COMPLETE -->
TASKS
git -C "$repo5" init -q
git -C "$repo5" commit --allow-empty -m "init" -q

state=$(detect_state "$repo5" "003" "003-secure-skip" 2>/dev/null)
assert_eq "review" "$state" "all tasks complete, force-skipped marker → review"

# ─── Test: security reviewed but no CI verification → "verify-ci" ────────

echo "Test: security reviewed, no CI verification returns 'verify-ci'"

repo6="$TMPDIR/repo-verify-ci"
mkdir -p "$repo6/specs/003-ci-pending"
echo "# spec" > "$repo6/specs/003-ci-pending/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo6/specs/003-ci-pending/spec.md"
echo "# plan" > "$repo6/specs/003-ci-pending/plan.md"
cat > "$repo6/specs/003-ci-pending/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_VERIFIED -->
<!-- SECURITY_REVIEWED -->
TASKS
git -C "$repo6" init -q
git -C "$repo6" commit --allow-empty -m "init" -q

state=$(detect_state "$repo6" "003" "003-ci-pending" 2>/dev/null)
assert_eq "verify-ci" "$state" "requirements verified + security reviewed, no VERIFY_CI_COMPLETE → verify-ci"

# ─── Test: all tasks complete, no REQUIREMENTS_VERIFIED → "verify-requirements" ─

echo "Test: all tasks complete, no REQUIREMENTS_VERIFIED → verify-requirements"

repo_vr1="$TMPDIR/repo-vr-pending"
mkdir -p "$repo_vr1/specs/003-vr-feat"
echo "# spec" > "$repo_vr1/specs/003-vr-feat/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr1/specs/003-vr-feat/spec.md"
echo "# plan" > "$repo_vr1/specs/003-vr-feat/plan.md"
cat > "$repo_vr1/specs/003-vr-feat/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
TASKS
git -C "$repo_vr1" init -q
git -C "$repo_vr1" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr1" "003" "003-vr-feat" 2>/dev/null)
assert_eq "verify-requirements" "$state" "all tasks complete, no REQUIREMENTS_VERIFIED → verify-requirements"

# ─── Test: REQUIREMENTS_VERIFIED present → "security-review" ─────────────

echo "Test: REQUIREMENTS_VERIFIED present → security-review"

repo_vr2="$TMPDIR/repo-vr-done"
mkdir -p "$repo_vr2/specs/003-vr-done"
echo "# spec" > "$repo_vr2/specs/003-vr-done/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr2/specs/003-vr-done/spec.md"
echo "# plan" > "$repo_vr2/specs/003-vr-done/plan.md"
cat > "$repo_vr2/specs/003-vr-done/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_VERIFIED -->
TASKS
git -C "$repo_vr2" init -q
git -C "$repo_vr2" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr2" "003" "003-vr-done" 2>/dev/null)
assert_eq "security-review" "$state" "REQUIREMENTS_VERIFIED present → security-review"

# ─── Test: REQUIREMENTS_FORCE_SKIPPED without REQUIREMENTS_VERIFIED → "verify-requirements" ─

echo "Test: REQUIREMENTS_FORCE_SKIPPED without REQUIREMENTS_VERIFIED → verify-requirements"

repo_vr3="$TMPDIR/repo-vr-force-skip"
mkdir -p "$repo_vr3/specs/003-vr-skip"
echo "# spec" > "$repo_vr3/specs/003-vr-skip/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr3/specs/003-vr-skip/spec.md"
echo "# plan" > "$repo_vr3/specs/003-vr-skip/plan.md"
cat > "$repo_vr3/specs/003-vr-skip/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_FORCE_SKIPPED -->
TASKS
git -C "$repo_vr3" init -q
git -C "$repo_vr3" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr3" "003" "003-vr-skip" 2>/dev/null)
assert_eq "verify-requirements" "$state" "REQUIREMENTS_FORCE_SKIPPED without VERIFIED → verify-requirements"

# ─── Test: both REQUIREMENTS_VERIFIED and FORCE_SKIPPED → "security-review" ─

echo "Test: both REQUIREMENTS_VERIFIED and FORCE_SKIPPED → security-review"

repo_vr4="$TMPDIR/repo-vr-both"
mkdir -p "$repo_vr4/specs/003-vr-both"
echo "# spec" > "$repo_vr4/specs/003-vr-both/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr4/specs/003-vr-both/spec.md"
echo "# plan" > "$repo_vr4/specs/003-vr-both/plan.md"
cat > "$repo_vr4/specs/003-vr-both/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_FORCE_SKIPPED -->
<!-- REQUIREMENTS_VERIFIED -->
TASKS
git -C "$repo_vr4" init -q
git -C "$repo_vr4" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr4" "003" "003-vr-both" 2>/dev/null)
assert_eq "security-review" "$state" "both REQUIREMENTS markers → security-review"

# ─── Test: deferred + complete mix, no REQUIREMENTS_VERIFIED → "verify-requirements" ─

echo "Test: deferred + complete mix, no REQUIREMENTS_VERIFIED → verify-requirements"

repo_vr5="$TMPDIR/repo-vr-deferred"
mkdir -p "$repo_vr5/specs/003-vr-def"
echo "# spec" > "$repo_vr5/specs/003-vr-def/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr5/specs/003-vr-def/spec.md"
echo "# plan" > "$repo_vr5/specs/003-vr-def/plan.md"
cat > "$repo_vr5/specs/003-vr-def/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [-] Task two (deferred)

<!-- ANALYZED -->
TASKS
git -C "$repo_vr5" init -q
git -C "$repo_vr5" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr5" "003" "003-vr-def" 2>/dev/null)
assert_eq "verify-requirements" "$state" "deferred+complete, no REQUIREMENTS_VERIFIED → verify-requirements"

# ─── Test: incomplete tasks → "implement" (not verify-requirements) ──────

echo "Test: incomplete tasks → implement (not verify-requirements)"

repo_vr6="$TMPDIR/repo-vr-incomplete"
mkdir -p "$repo_vr6/specs/003-vr-inc"
echo "# spec" > "$repo_vr6/specs/003-vr-inc/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr6/specs/003-vr-inc/spec.md"
echo "# plan" > "$repo_vr6/specs/003-vr-inc/plan.md"
cat > "$repo_vr6/specs/003-vr-inc/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [ ] Task two

<!-- ANALYZED -->
TASKS
git -C "$repo_vr6" init -q
git -C "$repo_vr6" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr6" "003" "003-vr-inc" 2>/dev/null)
assert_eq "implement" "$state" "incomplete tasks → implement (not verify-requirements)"

# ─── Test: REQUIREMENTS_VERIFIED + SECURITY_REVIEWED, no CI → "verify-ci" ─

echo "Test: REQUIREMENTS_VERIFIED + SECURITY_REVIEWED, no CI → verify-ci"

repo_vr7="$TMPDIR/repo-vr-to-ci"
mkdir -p "$repo_vr7/specs/003-vr-ci"
echo "# spec" > "$repo_vr7/specs/003-vr-ci/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr7/specs/003-vr-ci/spec.md"
echo "# plan" > "$repo_vr7/specs/003-vr-ci/plan.md"
cat > "$repo_vr7/specs/003-vr-ci/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_VERIFIED -->
<!-- SECURITY_REVIEWED -->
TASKS
git -C "$repo_vr7" init -q
git -C "$repo_vr7" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr7" "003" "003-vr-ci" 2>/dev/null)
assert_eq "verify-ci" "$state" "REQUIREMENTS_VERIFIED + SECURITY_REVIEWED, no CI → verify-ci"

# ─── Test: full pipeline markers present → "review" ─────────────────────

echo "Test: full pipeline markers present → review"

repo_vr8="$TMPDIR/repo-vr-full"
mkdir -p "$repo_vr8/specs/003-vr-full"
echo "# spec" > "$repo_vr8/specs/003-vr-full/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr8/specs/003-vr-full/spec.md"
echo "# plan" > "$repo_vr8/specs/003-vr-full/plan.md"
cat > "$repo_vr8/specs/003-vr-full/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_VERIFIED -->
<!-- SECURITY_REVIEWED -->
<!-- VERIFY_CI_COMPLETE -->
TASKS
git -C "$repo_vr8" init -q
git -C "$repo_vr8" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr8" "003" "003-vr-full" 2>/dev/null)
assert_eq "review" "$state" "all markers present → review"

# ─── Test: all-deferred tasks, no REQUIREMENTS_VERIFIED → "verify-requirements" ─

echo "Test: all-deferred tasks, no REQUIREMENTS_VERIFIED → verify-requirements"

repo_vr9="$TMPDIR/repo-vr-all-def"
mkdir -p "$repo_vr9/specs/003-vr-alldef"
echo "# spec" > "$repo_vr9/specs/003-vr-alldef/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_vr9/specs/003-vr-alldef/spec.md"
echo "# plan" > "$repo_vr9/specs/003-vr-alldef/plan.md"
cat > "$repo_vr9/specs/003-vr-alldef/tasks.md" << 'TASKS'
## Phase 1
- [-] Task one (deferred)
- [-] Task two (deferred)

<!-- ANALYZED -->
TASKS
git -C "$repo_vr9" init -q
git -C "$repo_vr9" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_vr9" "003" "003-vr-alldef" 2>/dev/null)
assert_eq "verify-requirements" "$state" "all-deferred, no REQUIREMENTS_VERIFIED → verify-requirements"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
