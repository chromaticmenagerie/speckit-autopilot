#!/usr/bin/env bash
# test-deferred.sh — Tests for deferred task handling (- [-] markers)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Harness ────────────────────────────────────────────────────────────
PASS=0 FAIL=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (expected=$expected, got=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Setup ───────────────────────────────────────────────────────────────────
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Minimal stubs
AUTOPILOT_LOG=""
BOLD="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM=""
MERGE_TARGET="master"
BASE_BRANCH="master"
log() { :; }
is_epic_merged() { return 1; }

source "$SRC_DIR/common.sh" 2>/dev/null || true
source "$SRC_DIR/autopilot-lib.sh" 2>/dev/null || {
    # If sourcing fails due to missing deps, define stubs
    :
}

# Helper to create a spec dir with tasks.md
make_spec() {
    local name="$1" content="$2"
    local dir="$TMPDIR_ROOT/specs/$name"
    mkdir -p "$dir"
    # Create spec.md with all required markers
    cat > "$dir/spec.md" <<'SPEC'
# Spec
<!-- CLARIFY_COMPLETE -->
<!-- CLARIFY_VERIFIED -->
SPEC
    cat > "$dir/plan.md" <<'PLAN'
# Plan
PLAN
    echo "$content" > "$dir/tasks.md"
    # Append ANALYZED marker
    echo "" >> "$dir/tasks.md"
    echo "<!-- ANALYZED -->" >> "$dir/tasks.md"
}

# ─── Tests: detect_state with deferred ──────────────────────────────────────
echo "== detect_state() with deferred tasks =="

# Mix of [x], [-], [ ] → returns "implement"
make_spec "001-mix-test" "## Phase 1
- [x] Done task
- [-] Deferred task
- [ ] Incomplete task"

result=$(detect_state "$TMPDIR_ROOT" "001" "001-mix-test")
assert_eq "mix of [x] [-] [ ] → implement" "implement" "$result"

# All [x] + some [-] → returns "security-review" (not implement)
make_spec "002-done-deferred" "## Phase 1
- [x] Done task 1
- [x] Done task 2
- [-] Deferred task"

result=$(detect_state "$TMPDIR_ROOT" "002" "002-done-deferred")
assert_eq "all [x] + some [-] → security-review" "security-review" "$result"

# All [-] zero [x] → returns "security-review" (not "tasks" edge case)
make_spec "003-all-deferred" "## Phase 1
- [-] Deferred task 1
- [-] Deferred task 2"

result=$(detect_state "$TMPDIR_ROOT" "003" "003-all-deferred")
assert_eq "all [-] zero [x] → security-review" "security-review" "$result"

# All [x] no [-] → returns "security-review" (existing behavior preserved)
make_spec "004-all-done" "## Phase 1
- [x] Done task 1
- [x] Done task 2"

result=$(detect_state "$TMPDIR_ROOT" "004" "004-all-done")
assert_eq "all [x] no [-] → security-review (preserved)" "security-review" "$result"

# ─── Tests: _gh_parse_tasks with deferred ───────────────────────────────────
echo ""
echo "== _gh_parse_tasks() with deferred tasks =="

# Only run if the function exists (it's in autopilot-github-sync.sh)
if type _gh_parse_tasks &>/dev/null; then
    parse_output=$(echo "## Phase 1
- [x] Done task
- [-] Deferred task
- [ ] Incomplete task" | _gh_parse_tasks)

    # Check that deferred task has checked="-"
    deferred_line=$(echo "$parse_output" | grep "Deferred" || true)
    if [[ "$deferred_line" == *"|-|"* ]]; then
        assert_eq "_gh_parse_tasks recognizes [-] as checked=-" "true" "true"
    else
        assert_eq "_gh_parse_tasks recognizes [-] as checked=-" "|-|" "not found"
    fi
else
    echo "  (skipped — _gh_parse_tasks not available)"
fi

# ─── Tests: get_current_impl_phase with deferred ────────────────────────────
echo ""
echo "== get_current_impl_phase() with deferred tasks =="

# Phase 1 all deferred, Phase 2 has incomplete → returns "2"
make_spec "005-phase-skip" "## Phase 1
- [-] Deferred task P1
- [-] Another deferred P1
## Phase 2
- [ ] Incomplete task P2"

# Remove the ANALYZED marker for this specific test
sed -i.bak '/<!-- ANALYZED -->/d' "$TMPDIR_ROOT/specs/005-phase-skip/tasks.md" 2>/dev/null || \
    sed -i '' '/<!-- ANALYZED -->/d' "$TMPDIR_ROOT/specs/005-phase-skip/tasks.md"
echo "<!-- ANALYZED -->" >> "$TMPDIR_ROOT/specs/005-phase-skip/tasks.md"

phase=$(get_current_impl_phase "$TMPDIR_ROOT/specs/005-phase-skip/tasks.md")
assert_eq "deferred Phase 1 → current phase is 2" "2" "$phase"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
