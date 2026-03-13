#!/usr/bin/env bash
# test-gates-extraction.sh — Verify gate functions extracted to autopilot-gates.sh.
#
# Usage: bash tests/test-gates-extraction.sh

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
echo -e "${BOLD}Gate Extraction Tests${RESET}"

# File exists
assert "autopilot-gates.sh exists" \
    "[[ -f '$REPO_ROOT/src/autopilot-gates.sh' ]]"

# Functions defined in gates file
assert "_run_security_gate defined in autopilot-gates.sh" \
    "grep -q '^_run_security_gate()' '$REPO_ROOT/src/autopilot-gates.sh'"

assert "_run_verify_ci_gate defined in autopilot-gates.sh" \
    "grep -q '^_run_verify_ci_gate()' '$REPO_ROOT/src/autopilot-gates.sh'"

# Functions NOT in autopilot.sh anymore
assert "_run_security_gate NOT in autopilot.sh" \
    "! grep -q '^_run_security_gate()' '$REPO_ROOT/src/autopilot.sh'"

assert "_run_verify_ci_gate NOT in autopilot.sh" \
    "! grep -q '^_run_verify_ci_gate()' '$REPO_ROOT/src/autopilot.sh'"

# Source line present in autopilot.sh
assert "autopilot-gates.sh sourced from autopilot.sh" \
    "grep -q 'source.*autopilot-gates.sh' '$REPO_ROOT/src/autopilot.sh'"

# Source ordering: gates after verify
assert "gates sourced after verify" \
    "awk '/autopilot-verify/{v=NR} /autopilot-gates/{g=NR} END{exit (v<g)?0:1}' '$REPO_ROOT/src/autopilot.sh'"

# CI_FIX_WARNINGS initialized in gates file
assert "CI_FIX_WARNINGS initialized in autopilot-gates.sh" \
    "grep -q '^CI_FIX_WARNINGS=' '$REPO_ROOT/src/autopilot-gates.sh'"

# install.sh includes gates
assert "autopilot-gates.sh in install.sh script list" \
    "grep -q 'autopilot-gates.sh' '$REPO_ROOT/install.sh'"

# ─── Summary ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
