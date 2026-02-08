#!/usr/bin/env bash
# test-install.sh — Smoke tests for the speckit-autopilot installer.
#
# Creates a temporary directory structure mimicking a Spec Kit project,
# runs install.sh, and verifies the expected files are in place.
#
# Usage: ./tests/test-install.sh

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

# ─── Setup ───────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

setup_speckit_project() {
    local dir="$1"
    mkdir -p "$dir/.specify/scripts/bash"
    mkdir -p "$dir/.specify/templates"
    mkdir -p "$dir/.specify/memory"
    # Minimal common.sh stub — just provides get_repo_root
    cat > "$dir/.specify/scripts/bash/common.sh" <<'STUB'
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
}
STUB
    # Init git repo for base branch detection
    (cd "$dir" && git init -q && git checkout -q -b main)
    (cd "$dir" && git add -A && git commit -q -m "init" --allow-empty)
}

# ─── Test 1: Fresh install ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Test 1: Fresh install on Spec Kit project${RESET}"

TEST1_DIR="$TMPDIR/test1"
mkdir -p "$TEST1_DIR"
setup_speckit_project "$TEST1_DIR"

(cd "$TEST1_DIR" && bash "$REPO_ROOT/install.sh") > /dev/null 2>&1

assert "autopilot.sh installed" "[[ -f '$TEST1_DIR/.specify/scripts/bash/autopilot.sh' ]]"
assert "autopilot-lib.sh installed" "[[ -f '$TEST1_DIR/.specify/scripts/bash/autopilot-lib.sh' ]]"
assert "autopilot-stream.sh installed" "[[ -f '$TEST1_DIR/.specify/scripts/bash/autopilot-stream.sh' ]]"
assert "autopilot-prompts.sh installed" "[[ -f '$TEST1_DIR/.specify/scripts/bash/autopilot-prompts.sh' ]]"
assert "autopilot-detect-project.sh installed" "[[ -f '$TEST1_DIR/.specify/scripts/bash/autopilot-detect-project.sh' ]]"
assert "skill file installed" "[[ -f '$TEST1_DIR/.claude/skills/autopilot/SKILL.md' ]]"
assert "version marker written" "[[ -f '$TEST1_DIR/.specify/autopilot-version' ]]"
assert "version is 0.2.0" "[[ \"\$(cat '$TEST1_DIR/.specify/autopilot-version')\" == '0.2.0' ]]"
assert "project.env generated" "[[ -f '$TEST1_DIR/.specify/project.env' ]]"
assert "project.env has BASE_BRANCH" "grep -q 'BASE_BRANCH=' '$TEST1_DIR/.specify/project.env'"
assert "scripts are executable" "[[ -x '$TEST1_DIR/.specify/scripts/bash/autopilot.sh' ]]"

# ─── Test 2: Idempotent re-install (same version) ───────────────────────────

echo ""
echo -e "${BOLD}Test 2: Re-install same version (idempotent)${RESET}"

OUTPUT2=$(cd "$TEST1_DIR" && bash "$REPO_ROOT/install.sh" 2>&1)

assert "says already up to date" "echo '$OUTPUT2' | grep -q 'Already up to date'"

# ─── Test 3: Upgrade path ───────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Test 3: Upgrade from older version${RESET}"

echo "0.0.1" > "$TEST1_DIR/.specify/autopilot-version"

OUTPUT3=$(cd "$TEST1_DIR" && bash "$REPO_ROOT/install.sh" 2>&1)

assert "says upgrading" "echo '$OUTPUT3' | grep -q 'Upgrading'"
assert "version updated to 0.2.0" "[[ \"\$(cat '$TEST1_DIR/.specify/autopilot-version')\" == '0.2.0' ]]"

# ─── Test 4: Fails without Spec Kit ─────────────────────────────────────────

echo ""
echo -e "${BOLD}Test 4: Refuses install without Spec Kit${RESET}"

TEST4_DIR="$TMPDIR/test4"
mkdir -p "$TEST4_DIR"
(cd "$TEST4_DIR" && git init -q)

OUTPUT4=$(cd "$TEST4_DIR" && bash "$REPO_ROOT/install.sh" 2>&1 || true)

assert "error mentions Spec Kit" "echo '$OUTPUT4' | grep -q 'Spec Kit not found'"

# ─── Test 5: Fails with incomplete Spec Kit ──────────────────────────────────

echo ""
echo -e "${BOLD}Test 5: Refuses install with incomplete Spec Kit${RESET}"

TEST5_DIR="$TMPDIR/test5"
mkdir -p "$TEST5_DIR/.specify"
(cd "$TEST5_DIR" && git init -q)

OUTPUT5=$(cd "$TEST5_DIR" && bash "$REPO_ROOT/install.sh" 2>&1 || true)

assert "error mentions incomplete" "echo '$OUTPUT5' | grep -q 'incomplete'"

# ─── Test 6: project.env not overwritten on upgrade ─────────────────────────

echo ""
echo -e "${BOLD}Test 6: project.env preserved on upgrade${RESET}"

echo "0.0.9" > "$TEST1_DIR/.specify/autopilot-version"
echo 'PROJECT_TEST_CMD="custom test cmd"' > "$TEST1_DIR/.specify/project.env"

(cd "$TEST1_DIR" && bash "$REPO_ROOT/install.sh") > /dev/null 2>&1

PRESERVED_CMD=$(grep 'PROJECT_TEST_CMD' "$TEST1_DIR/.specify/project.env" || true)
assert "project.env preserved" "echo '$PRESERVED_CMD' | grep -q 'custom test cmd'"

# ─── Test 7: Legacy .claude/commands/ cleaned up on upgrade ──────────────────

echo ""
echo -e "${BOLD}Test 7: Legacy commands cleaned up on upgrade${RESET}"

mkdir -p "$TEST1_DIR/.claude/commands"
echo "old" > "$TEST1_DIR/.claude/commands/autopilot.md"
echo "0.0.1" > "$TEST1_DIR/.specify/autopilot-version"

(cd "$TEST1_DIR" && bash "$REPO_ROOT/install.sh") > /dev/null 2>&1

assert "legacy command removed" "[[ ! -f '$TEST1_DIR/.claude/commands/autopilot.md' ]]"
assert "skill in new location" "[[ -f '$TEST1_DIR/.claude/skills/autopilot/SKILL.md' ]]"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}════════════════════════════════════════${RESET}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
