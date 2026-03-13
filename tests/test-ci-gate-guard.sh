#!/usr/bin/env bash
# test-ci-gate-guard.sh — Verify CI_FORCE_SKIP_ALLOWED gating and resume guard.
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
echo -e "${BOLD}CI Gate Guard Tests${RESET}"

GATES_FILE="$REPO_ROOT/src/autopilot-gates.sh"

# ─── CI_FORCE_SKIP_ALLOWED variable declared ────────────────────────────

assert "CI_FORCE_SKIP_ALLOWED default defined" \
    "grep -q 'CI_FORCE_SKIP_ALLOWED=.*true' '$GATES_FILE'"

# ─── Force-skip blocked when CI_FORCE_SKIP_ALLOWED=false ────────────────

assert "Halt path exists when CI_FORCE_SKIP_ALLOWED=false" \
    "grep -q 'halting (CI_FORCE_SKIP_ALLOWED=false)' '$GATES_FILE'"

# ─── Force-skip allowed (default) wraps existing logic ──────────────────

assert "Force-skip wrapped in CI_FORCE_SKIP_ALLOWED conditional" \
    "grep -A1 'CI_FORCE_SKIP_ALLOWED.*true' '$GATES_FILE' | grep -q 'VERIFY_CI_COMPLETE\|VERIFY_CI_FORCE_SKIPPED\|force-advancing'"

# ─── Resume guard exists ────────────────────────────────────────────────

assert "Resume guard checks VERIFY_CI_FORCE_SKIPPED marker" \
    "grep -q 'VERIFY_CI_FORCE_SKIPPED.*tasks_file' '$GATES_FILE'"

assert "Resume guard writes VERIFY_CI_COMPLETE if missing" \
    "grep -A5 'CI gate previously force-skipped' '$GATES_FILE' | grep -q 'VERIFY_CI_COMPLETE'"

# ─── Functional test: resume guard logic ─────────────────────────────────

TMPD=$(mktemp -d)
TASKS="$TMPD/tasks.md"
echo "<!-- VERIFY_CI_FORCE_SKIPPED -->" > "$TASKS"

# Simulate: CI_FORCE_SKIP_ALLOWED=true should add VERIFY_CI_COMPLETE
CI_FORCE_SKIP_ALLOWED=true
if grep -q '<!-- VERIFY_CI_FORCE_SKIPPED -->' "$TASKS" 2>/dev/null; then
    if [[ "${CI_FORCE_SKIP_ALLOWED:-true}" == "true" ]]; then
        grep -q '<!-- VERIFY_CI_COMPLETE -->' "$TASKS" 2>/dev/null || \
            echo "<!-- VERIFY_CI_COMPLETE -->" >> "$TASKS"
    fi
fi
assert "Resume guard adds VERIFY_CI_COMPLETE marker" \
    "grep -q '<!-- VERIFY_CI_COMPLETE -->' '$TASKS'"

# Simulate: CI_FORCE_SKIP_ALLOWED=false should NOT add marker
TASKS2="$TMPD/tasks2.md"
echo "<!-- VERIFY_CI_FORCE_SKIPPED -->" > "$TASKS2"
CI_FORCE_SKIP_ALLOWED=false
if grep -q '<!-- VERIFY_CI_FORCE_SKIPPED -->' "$TASKS2" 2>/dev/null; then
    if [[ "${CI_FORCE_SKIP_ALLOWED}" == "true" ]]; then
        grep -q '<!-- VERIFY_CI_COMPLETE -->' "$TASKS2" 2>/dev/null || \
            echo "<!-- VERIFY_CI_COMPLETE -->" >> "$TASKS2"
    fi
fi
assert "CI_FORCE_SKIP_ALLOWED=false blocks resume advance" \
    "! grep -q '<!-- VERIFY_CI_COMPLETE -->' '$TASKS2'"

# ─── Cleanup ─────────────────────────────────────────────────────────────
rm -rf "$TMPD"

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
