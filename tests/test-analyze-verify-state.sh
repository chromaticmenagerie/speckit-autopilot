#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/src"

TESTS=0 PASSED=0 FAILED=0
assert_eq() {
    local expected="$1" actual="$2" label="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASSED=$((PASSED + 1))
        echo "  ✓ $label"
    else
        FAILED=$((FAILED + 1))
        echo "  ✗ $label (expected '$expected', got '$actual')"
    fi
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

AUTOPILOT_LOG=""
BASE_BRANCH="master"
source "$SRC_DIR/autopilot-lib.sh"

# Stub out functions detect_state depends on
find_pen_file() { echo ""; }
is_epic_merged() { return 1; }

# --- Test 1: tasks.md with no markers → "analyze" ---
echo "Test: tasks.md with no markers returns 'analyze'"
t1="$TMPDIR/t1"
mkdir -p "$t1/specs/003-test"
cat > "$t1/specs/003-test/spec.md" << 'SPEC'
# Test spec
<!-- CLARIFY_COMPLETE -->
<!-- CLARIFY_VERIFIED -->
SPEC
cat > "$t1/specs/003-test/plan.md" << 'PLAN'
# Plan
PLAN
cat > "$t1/specs/003-test/tasks.md" << 'TASKS'
# Tasks
- [ ] Task 1
TASKS
result="$(detect_state "$t1" "003" "003-test" 2>/dev/null)"
assert_eq "analyze" "$result" "no markers → analyze"

# --- Test 2: tasks.md with FIXES APPLIED but no ANALYZED → "analyze-verify" ---
echo "Test: tasks.md with FIXES APPLIED returns 'analyze-verify'"
t2="$TMPDIR/t2"
mkdir -p "$t2/specs/003-test"
cat > "$t2/specs/003-test/spec.md" << 'SPEC'
# Test spec
<!-- CLARIFY_COMPLETE -->
<!-- CLARIFY_VERIFIED -->
SPEC
cat > "$t2/specs/003-test/plan.md" << 'PLAN'
# Plan
PLAN
cat > "$t2/specs/003-test/tasks.md" << 'TASKS'
# Tasks
- [ ] Task 1
<!-- FIXES APPLIED -->
TASKS
result="$(detect_state "$t2" "003" "003-test" 2>/dev/null)"
assert_eq "analyze-verify" "$result" "FIXES APPLIED only → analyze-verify"

# --- Test 3: tasks.md with ANALYZED → advances past analyze ---
echo "Test: tasks.md with ANALYZED advances past analyze"
t3="$TMPDIR/t3"
mkdir -p "$t3/specs/003-test"
cat > "$t3/specs/003-test/spec.md" << 'SPEC'
# Test spec
<!-- CLARIFY_COMPLETE -->
<!-- CLARIFY_VERIFIED -->
SPEC
cat > "$t3/specs/003-test/plan.md" << 'PLAN'
# Plan
PLAN
cat > "$t3/specs/003-test/tasks.md" << 'TASKS'
# Tasks
- [ ] Task 1
<!-- ANALYZED -->
TASKS
result="$(detect_state "$t3" "003" "003-test" 2>/dev/null)"
assert_eq "implement" "$result" "ANALYZED → implement"

# --- Test 4: tasks.md with BOTH markers → ANALYZED takes precedence ---
echo "Test: both markers → ANALYZED takes precedence"
t4="$TMPDIR/t4"
mkdir -p "$t4/specs/003-test"
cat > "$t4/specs/003-test/spec.md" << 'SPEC'
# Test spec
<!-- CLARIFY_COMPLETE -->
<!-- CLARIFY_VERIFIED -->
SPEC
cat > "$t4/specs/003-test/plan.md" << 'PLAN'
# Plan
PLAN
cat > "$t4/specs/003-test/tasks.md" << 'TASKS'
# Tasks
- [ ] Task 1
<!-- FIXES APPLIED -->
<!-- ANALYZED -->
TASKS
result="$(detect_state "$t4" "003" "003-test" 2>/dev/null)"
assert_eq "implement" "$result" "both markers → ANALYZED precedence"

echo ""
echo "Results: $PASSED/$TESTS passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
