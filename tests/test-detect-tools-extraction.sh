#!/usr/bin/env bash
# test-detect-tools-extraction.sh — Verify detection functions extracted to autopilot-detect-tools.sh.
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
echo -e "${BOLD}Detect-Tools Extraction Tests${RESET}"

# File exists
assert "autopilot-detect-tools.sh exists" \
    "[[ -f '$REPO_ROOT/src/autopilot-detect-tools.sh' ]]"

# Functions defined in detect-tools
for func in _ensure_gitignore_logs detect_python detect_node_monorepo detect_node detect_rust detect_go detect_makefile detect_base_branch detect_coderabbit_cli detect_remote detect_gh_cli detect_gitleaks _generate_gitleaks_config; do
    assert "$func defined in detect-tools.sh" \
        "grep -q '^${func}()' '$REPO_ROOT/src/autopilot-detect-tools.sh'"
done

# Functions NOT in detect-project.sh
for func in detect_python detect_node_monorepo detect_node detect_rust detect_go detect_makefile detect_base_branch detect_coderabbit_cli detect_remote detect_gh_cli _ensure_gitignore_logs; do
    assert "$func NOT in detect-project.sh" \
        "! grep -q '^${func}()' '$REPO_ROOT/src/autopilot-detect-project.sh'"
done

# Source line in detect-project.sh
assert "detect-tools.sh sourced from detect-project.sh" \
    "grep -q 'source.*autopilot-detect-tools.sh' '$REPO_ROOT/src/autopilot-detect-project.sh'"

# install.sh includes detect-tools
assert "autopilot-detect-tools.sh in install.sh script list" \
    "grep -q 'autopilot-detect-tools.sh' '$REPO_ROOT/install.sh'"

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

[[ $TESTS_FAILED -eq 0 ]] || exit 1
