#!/usr/bin/env bash
# test-security-verify.sh — Verify security-verify phase registration, prompts, and integration.
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/src"

# ─── Test Framework ─────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
RESET='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}PASS${RESET} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}FAIL${RESET} $1"; }

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} $msg: '$needle' not found in output"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} $msg: '$needle' should NOT appear in output"
    fi
}

echo ""
echo -e "${BOLD}Security-Verify Phase Tests${RESET}"

AUTOPILOT_FILE="$SRC_DIR/autopilot.sh"
GATES_FILE="$SRC_DIR/autopilot-gates.sh"
PROMPTS_FILE="$SRC_DIR/autopilot-prompts.sh"
WATCH_FILE="$SRC_DIR/autopilot-watch.sh"
GITHUB_FILE="$SRC_DIR/autopilot-github.sh"
LIB_FILE="$SRC_DIR/autopilot-lib.sh"

# ─── 1. Phase registration ─────────────────────────────────────────────────

echo ""
echo "Phase registration"

grep -q '\[security-verify\]=' "$AUTOPILOT_FILE" && pass "PHASE_MODEL contains security-verify" || fail "PHASE_MODEL contains security-verify"
grep -q '\[security-verify\]="Read,Glob,Grep,Bash"' "$AUTOPILOT_FILE" && pass "PHASE_TOOLS[security-verify] = Read,Glob,Grep,Bash" || fail "PHASE_TOOLS[security-verify] = Read,Glob,Grep,Bash"
grep -q '\[security-verify\]=1' "$AUTOPILOT_FILE" && pass "PHASE_MAX_RETRIES[security-verify] = 1" || fail "PHASE_MAX_RETRIES[security-verify] = 1"

# ─── 2. Watch dashboard PHASES array ───────────────────────────────────────

echo ""
echo "Watch dashboard"

# Verify security-verify is in PHASES between security-review and verify-ci
phases_line=$(grep '^PHASES=' "$WATCH_FILE")
[[ -n "$phases_line" ]] && pass "PHASES array defined in watch" || fail "PHASES array defined in watch"

# Check ordering: security-review then security-verify then verify-ci
if echo "$phases_line" | grep -q 'security-review security-verify verify-ci'; then
    pass "security-verify between security-review and verify-ci in PHASES"
else
    fail "security-verify between security-review and verify-ci in PHASES"
fi

# ─── 3. GitHub status mapping ──────────────────────────────────────────────

echo ""
echo "GitHub status mapping"

grep -q 'security-verify' "$GITHUB_FILE" && pass "security-verify in _gh_phase_to_status case" || fail "security-verify in _gh_phase_to_status case"
# Verify it maps to "In Progress" (same case arm as security-review)
if grep 'security-verify' "$GITHUB_FILE" | grep -q 'In Progress'; then
    pass "_gh_phase_to_status maps security-verify to In Progress"
else
    # It may be in a combined case line — check the pattern
    phase_case_line=$(grep 'security-verify' "$GITHUB_FILE" | head -1)
    if echo "$phase_case_line" | grep -q 'In Progress'; then
        pass "_gh_phase_to_status maps security-verify to In Progress"
    else
        # Check if it's in a case block that echoes "In Progress" on the next line
        if awk '/security-verify/{found=1} found && /In Progress/{print; exit}' "$GITHUB_FILE" | grep -q 'In Progress'; then
            pass "_gh_phase_to_status maps security-verify to In Progress"
        else
            fail "_gh_phase_to_status maps security-verify to In Progress"
        fi
    fi
fi

# ─── 4. Prompt function exists ─────────────────────────────────────────────

echo ""
echo "Prompt function"

grep -q '^prompt_security_verify()' "$PROMPTS_FILE" && pass "prompt_security_verify defined in autopilot-prompts.sh" || fail "prompt_security_verify defined in autopilot-prompts.sh"

# ─── 5. Prompt output format ──────────────────────────────────────────────

echo ""
echo "Prompt output format"

# Setup stubs for prompt function sourcing
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

log() { :; }
_preamble() { echo "PREAMBLE"; }
MERGE_TARGET="main"
BASE_BRANCH="main"
LAST_MERGE_SHA="abc123"
PROJECT_TEST_CMD=""
PROJECT_LINT_CMD=""
PROJECT_WORK_DIR=""
HAS_FRONTEND="false"

source "$PROMPTS_FILE"

output="$(prompt_security_verify "001" "test epic" "/tmp/repo" "001-test-epic" "1" "3")"

assert_contains "$output" "IMPORTANT: Read .specify/memory" "prompt contains preamble"
assert_contains "$output" "security-findings.md" "prompt references findings file"
assert_contains "$output" "Verdict:" "prompt contains Verdict format"
assert_contains "$output" "Do NOT modify source code" "prompt contains prohibitions"
assert_contains "$output" "Verify Cycle" "prompt contains verify cycle header"
assert_contains "$output" "RESOLVED" "prompt mentions RESOLVED status"
assert_contains "$output" "UNRESOLVED" "prompt mentions UNRESOLVED status"
assert_contains "$output" "REGRESSED" "prompt mentions REGRESSED status"
assert_contains "$output" "ACCEPTED" "prompt mentions ACCEPTED status"

# ─── 6. Prompt has no shell expansion ─────────────────────────────────────

echo ""
echo "Prompt shell safety"

# The prompt should not expand variables like $HOME or $(whoami)
assert_not_contains "$output" '$(whoami)' "prompt has no \$(whoami) expansion"
# Verify the prompt references file path rather than inlining content
assert_contains "$output" "/tmp/repo/specs/001-test-epic/security-findings.md" "prompt references full findings file path"

# ─── 7. State detection unchanged ─────────────────────────────────────────

echo ""
echo "State detection regression check"

# Source autopilot-lib.sh for detect_state
AUTOPILOT_LOG=""
source "$SRC_DIR/autopilot-lib.sh"

# Stub helpers
find_pen_file() { echo ""; }
is_epic_merged() { return 1; }

repo_sv="$TMPDIR_TEST/repo-sv-regression"
mkdir -p "$repo_sv/specs/003-sv-feat"
echo "# spec" > "$repo_sv/specs/003-sv-feat/spec.md"
echo -e "<!-- CLARIFY_COMPLETE -->\n<!-- CLARIFY_VERIFIED -->" >> "$repo_sv/specs/003-sv-feat/spec.md"
echo "# plan" > "$repo_sv/specs/003-sv-feat/plan.md"
cat > "$repo_sv/specs/003-sv-feat/tasks.md" << 'TASKS'
## Phase 1
- [x] Task one
- [x] Task two

<!-- ANALYZED -->
<!-- REQUIREMENTS_VERIFIED -->
TASKS
git -C "$repo_sv" init -q
git -C "$repo_sv" commit --allow-empty -m "init" -q

state=$(detect_state "$repo_sv" "003" "003-sv-feat" 2>/dev/null)
if [[ "$state" == "security-review" ]]; then
    pass "detect_state returns security-review when REQUIREMENTS_VERIFIED present, SECURITY_REVIEWED absent"
else
    fail "detect_state returns security-review when REQUIREMENTS_VERIFIED present, SECURITY_REVIEWED absent (got: '$state')"
fi

# ─── 8. Max rounds default ────────────────────────────────────────────────

echo ""
echo "Max rounds default"

# In autopilot-gates.sh, the fallback default is 3: ${SECURITY_MAX_ROUNDS:-3}
if grep -q 'SECURITY_MAX_ROUNDS:-3' "$GATES_FILE"; then
    pass "SECURITY_MAX_ROUNDS gates fallback is 3"
else
    fail "SECURITY_MAX_ROUNDS gates fallback is 3"
fi

# ─── 9. Gate function structural check ────────────────────────────────────

echo ""
echo "Gate function structural check"

grep -q '^_run_security_gate()' "$GATES_FILE" && pass "_run_security_gate defined in autopilot-gates.sh" || fail "_run_security_gate defined in autopilot-gates.sh"

# Verify the gate dispatches security-verify
grep -q 'invoke_claude "security-verify"' "$GATES_FILE" && pass "_run_security_gate dispatches security-verify phase" || fail "_run_security_gate dispatches security-verify phase"

# Verify prompt_security_verify is called from the gate
grep -q 'prompt_security_verify' "$GATES_FILE" && pass "gate calls prompt_security_verify" || fail "gate calls prompt_security_verify"

# ─── Summary ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
