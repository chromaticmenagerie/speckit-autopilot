#!/usr/bin/env bash
# test-ci-same-failure.sh — Verify same-failure detection halts CI loop early.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert() {
    local desc="$1"
    local condition="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if eval "$condition"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} $desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} $desc"
    fi
}

echo ""
echo -e "${BOLD}CI Same-Failure Detection Tests${RESET}"

GATES_FILE="$REPO_ROOT/src/autopilot-gates.sh"

# ─── Structural tests ──────────────────────────────────────────────────

assert "prev_ci_output initialized before while loop" \
    "grep -q 'local prev_ci_output=\"\"' '$GATES_FILE'"

assert "Same-failure comparison uses LAST_CI_OUTPUT and prev_ci_output" \
    "grep -q 'LAST_CI_OUTPUT.*==.*prev_ci_output' '$GATES_FILE'"

assert "Same-failure guard checks CI_FIX_TEST_WARN is empty" \
    "grep -q 'CI_FIX_TEST_WARN:-' '$GATES_FILE'"

assert "ci_fix_no_progress event emitted on same-failure" \
    "grep -q 'ci_fix_no_progress' '$GATES_FILE'"

assert "prev_ci_output updated at end of loop body" \
    "grep -q 'prev_ci_output=.\$LAST_CI_OUTPUT.' '$GATES_FILE'"

assert "Same-failure check before max_rounds check (ordering)" \
    "awk '/Same-failure early halt/{a=NR} /round -ge .max_rounds.*&& break/{b=NR} END{exit (a && b && a<b) ? 0 : 1}' '$GATES_FILE'"

assert "Force-skip markers written on same-failure halt" \
    "grep -A8 'no progress, halting early' '$GATES_FILE' | grep -q 'VERIFY_CI_FORCE_SKIPPED'"

# ─── Functional tests ──────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Functional: same-failure early halt${RESET}"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# Mock functions
log() { echo "LOG:$1:$2" >> "$TMPD/log.out"; }
verify_ci() { return 1; }
_emit_event() { echo "$2" >> "$TMPD/events.out"; }
_accumulate_phase_cost() { :; }
_detect_test_modifications() { :; }
invoke_claude() { :; }
prompt_verify_ci_fix() { echo "fix prompt"; }

export -f log verify_ci _emit_event _accumulate_phase_cost _detect_test_modifications invoke_claude prompt_verify_ci_fix

# --- Test: identical output triggers early halt ---
setup_test() {
    rm -f "$TMPD"/*.out
    mkdir -p "$TMPD/specs/test-epic" "$TMPD/.specify/logs"
    echo "# tasks" > "$TMPD/specs/test-epic/tasks.md"
    touch "$TMPD/.specify/logs/events.jsonl"
}

setup_test
LAST_CI_OUTPUT="error: something broke"
CI_FIX_TEST_WARN=""
CI_FIX_WARNINGS=""
DRY_RUN=false
CI_FORCE_SKIP_ALLOWED=true
PROJECT_TEST_CMD="echo test"

# Simulate: two rounds with identical CI output
# Round 1: verify_ci fails, prev_ci_output="" so no match, then fix runs
# Round 2: verify_ci fails, LAST_CI_OUTPUT == prev_ci_output -> halt
# We need a mini simulation since sourcing the full function requires too many deps.

prev_ci_output=""
round=0
max_rounds=3
halted_early=false
tasks_file="$TMPD/specs/test-epic/tasks.md"
events_log="$TMPD/.specify/logs/events.jsonl"
repo_root="$TMPD"
epic_num="001"

while [[ $round -lt $max_rounds ]]; do
    round=$((round + 1))
    # verify_ci always fails
    # Check same-failure
    if [[ -n "$prev_ci_output" ]] && [[ "$LAST_CI_OUTPUT" == "$prev_ci_output" ]] && [[ -z "${CI_FIX_TEST_WARN:-}" ]]; then
        _emit_event "$events_log" "ci_fix_no_progress" \
            "{\"round\":$round,\"detail\":\"CI output unchanged from round $((round-1))\"}"
        if [[ "${CI_FORCE_SKIP_ALLOWED:-true}" == "true" ]]; then
            echo "<!-- VERIFY_CI_COMPLETE -->" >> "$tasks_file"
            echo "<!-- VERIFY_CI_FORCE_SKIPPED -->" >> "$tasks_file"
        fi
        halted_early=true
        break
    fi
    [[ $round -ge $max_rounds ]] && break
    # "fix" runs but output stays the same
    prev_ci_output="$LAST_CI_OUTPUT"
done

assert "Identical CI output triggers early halt" \
    "[[ '$halted_early' == 'true' ]]"

assert "Early halt happened at round 2 (not 3)" \
    "[[ $round -eq 2 ]]"

assert "Force-skip marker written on early halt" \
    "grep -q '<!-- VERIFY_CI_FORCE_SKIPPED -->' '$tasks_file'"

assert "VERIFY_CI_COMPLETE marker written on early halt" \
    "grep -q '<!-- VERIFY_CI_COMPLETE -->' '$tasks_file'"

assert "ci_fix_no_progress event emitted" \
    "grep -q 'ci_fix_no_progress' '$TMPD/events.out'"

# --- Test: different output does NOT trigger early halt ---
echo ""
echo -e "${BOLD}Functional: different output continues loop${RESET}"

setup_test
prev_ci_output=""
round=0
max_rounds=3
halted_early=false
tasks_file="$TMPD/specs/test-epic/tasks.md"
ci_outputs=("error: first failure" "error: second failure" "error: third failure")

while [[ $round -lt $max_rounds ]]; do
    round=$((round + 1))
    LAST_CI_OUTPUT="${ci_outputs[$((round-1))]}"
    CI_FIX_TEST_WARN=""
    if [[ -n "$prev_ci_output" ]] && [[ "$LAST_CI_OUTPUT" == "$prev_ci_output" ]] && [[ -z "${CI_FIX_TEST_WARN:-}" ]]; then
        halted_early=true
        break
    fi
    [[ $round -ge $max_rounds ]] && break
    prev_ci_output="$LAST_CI_OUTPUT"
done

assert "Different CI output does NOT trigger early halt" \
    "[[ '$halted_early' == 'false' ]]"

assert "Loop ran to max_rounds with different output" \
    "[[ $round -eq 3 ]]"

# --- Test: CI_FIX_TEST_WARN suppresses same-failure halt ---
echo ""
echo -e "${BOLD}Functional: test modifications suppress same-failure halt${RESET}"

setup_test
prev_ci_output=""
round=0
max_rounds=2
halted_early=false
LAST_CI_OUTPUT="error: something broke"
CI_FIX_TEST_WARN=""

while [[ $round -lt $max_rounds ]]; do
    round=$((round + 1))
    # Same-failure check — CI_FIX_TEST_WARN persists from previous round's fix phase
    if [[ -n "$prev_ci_output" ]] && [[ "$LAST_CI_OUTPUT" == "$prev_ci_output" ]] && [[ -z "${CI_FIX_TEST_WARN:-}" ]]; then
        halted_early=true
        break
    fi
    [[ $round -ge $max_rounds ]] && break
    # Simulate fix phase: sets CI_FIX_TEST_WARN (persists to round 2 check)
    CI_FIX_TEST_WARN="WARN: tests modified"
    prev_ci_output="$LAST_CI_OUTPUT"
done

assert "CI_FIX_TEST_WARN suppresses same-failure halt (reached max_rounds)" \
    "[[ '$halted_early' == 'false' ]]"

assert "Loop reached max_rounds when test warn present" \
    "[[ $round -eq 2 ]]"

# --- Test: CI_FORCE_SKIP_ALLOWED=false skips markers ---
echo ""
echo -e "${BOLD}Functional: force-skip disabled omits markers${RESET}"

setup_test
prev_ci_output=""
round=0
max_rounds=3
tasks_file="$TMPD/specs/test-epic/tasks.md"
CI_FORCE_SKIP_ALLOWED=false
LAST_CI_OUTPUT="error: something broke"

while [[ $round -lt $max_rounds ]]; do
    round=$((round + 1))
    CI_FIX_TEST_WARN=""
    if [[ -n "$prev_ci_output" ]] && [[ "$LAST_CI_OUTPUT" == "$prev_ci_output" ]] && [[ -z "${CI_FIX_TEST_WARN:-}" ]]; then
        if [[ "${CI_FORCE_SKIP_ALLOWED:-true}" == "true" ]]; then
            echo "<!-- VERIFY_CI_COMPLETE -->" >> "$tasks_file"
            echo "<!-- VERIFY_CI_FORCE_SKIPPED -->" >> "$tasks_file"
        fi
        break
    fi
    [[ $round -ge $max_rounds ]] && break
    prev_ci_output="$LAST_CI_OUTPUT"
done

assert "CI_FORCE_SKIP_ALLOWED=false: no VERIFY_CI_COMPLETE marker" \
    "! grep -q '<!-- VERIFY_CI_COMPLETE -->' '$tasks_file'"

assert "CI_FORCE_SKIP_ALLOWED=false: no VERIFY_CI_FORCE_SKIPPED marker" \
    "! grep -q '<!-- VERIFY_CI_FORCE_SKIPPED -->' '$tasks_file'"

# ─── Summary ────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
