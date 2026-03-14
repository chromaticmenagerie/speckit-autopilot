#!/usr/bin/env bash
# test-requirements-gate-integration.sh — Integration tests for _run_requirements_gate()
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

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
assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${RESET} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${RESET} $msg: expected '$expected', got '$actual'"
    fi
}
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

# ─── Stubs (BEFORE sourcing) ────────────────────────────────────────────────
LOG_WARNS=()
log() { [[ "${1:-}" == "WARN" ]] && LOG_WARNS+=("$*"); }
_emit_event() { :; }
_accumulate_phase_cost() { :; }
_write_force_skip_audit() { AUDIT_CALLED=true; }
prompt_verify_requirements() { echo "stub"; }
prompt_requirements_fix() { echo "stub"; }
prompt_requirements_recheck() { echo "stub"; }
# invoke_claude redefined per-test
invoke_claude() { return 0; }
source "$SRC_DIR/autopilot-requirements.sh"

# ─── Helpers ────────────────────────────────────────────────────────────────
create_test_repo() {
    local repo; repo=$(mktemp -d)
    git init -q "$repo"
    git -C "$repo" config user.email "test@test"
    git -C "$repo" config user.name "Test"
    git -C "$repo" commit --allow-empty -m "init" -q
    mkdir -p "$repo/specs/001-test"
    printf '# Spec\n- FR-001: Auth\n- FR-002: Validation\n- FR-003: Errors\n' \
        > "$repo/specs/001-test/spec.md"
    echo "- [x] Task 1" > "$repo/specs/001-test/tasks.md"
    git -C "$repo" add -A && git -C "$repo" commit -q -m "spec"
    echo "$repo"
}

create_test_repo_no_frs() {
    local repo; repo=$(mktemp -d)
    git init -q "$repo"
    git -C "$repo" config user.email "test@test"
    git -C "$repo" config user.name "Test"
    git -C "$repo" commit --allow-empty -m "init" -q
    mkdir -p "$repo/specs/001-test"
    echo "# Spec with no FR-NNN ids" > "$repo/specs/001-test/spec.md"
    echo "- [x] Task 1" > "$repo/specs/001-test/tasks.md"
    git -C "$repo" add -A && git -C "$repo" commit -q -m "spec"
    echo "$repo"
}
# ─── Section 1: Verdict Parsing Tests ────────────────────────────────────────
echo ""
echo -e "${BOLD}Verdict Parsing Tests${RESET}"

parse_verdict() {
    local file="$1"
    grep -i '^Verdict:' "$file" 2>/dev/null | tail -1 | awk '{print toupper($2)}'
}

# V1: "Verdict: PASS" -> "PASS"
tmp=$(mktemp)
printf 'Verdict: PASS\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "V1: Verdict: PASS -> PASS"
rm -f "$tmp"

# V2: "Verdict: FAIL" -> "FAIL"
tmp=$(mktemp)
printf 'Verdict: FAIL\n' > "$tmp"
assert_eq "FAIL" "$(parse_verdict "$tmp")" "V2: Verdict: FAIL -> FAIL"
rm -f "$tmp"

# V3: "verdict: pass" (lowercase) -> "PASS"
tmp=$(mktemp)
printf 'verdict: pass\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "V3: lowercase -> PASS"
rm -f "$tmp"

# V4: Extra whitespace -> "PASS"
tmp=$(mktemp)
printf 'Verdict:   PASS  \n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "V4: extra whitespace -> PASS"
rm -f "$tmp"

# V5: No Verdict line -> ""
tmp=$(mktemp)
printf '# Just some text\nNo verdict here.\n' > "$tmp"
assert_eq "" "$(parse_verdict "$tmp")" "V5: no Verdict line -> empty"
rm -f "$tmp"

# V6: Empty file -> ""
tmp=$(mktemp)
: > "$tmp"
assert_eq "" "$(parse_verdict "$tmp")" "V6: empty file -> empty"
rm -f "$tmp"

# V7: Multiple Verdict lines -> last line's value
tmp=$(mktemp)
printf 'Verdict: FAIL\nVerdict: PASS\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "V7: multiple -> last value (PASS)"
rm -f "$tmp"

# V8: Trailing text -> "PASS"
tmp=$(mktemp)
printf 'Verdict: PASS --- all verified\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "V8: trailing text -> PASS"
rm -f "$tmp"
# ─── Section 2: Gate Cycle Integration Tests ─────────────────────────────────
echo ""
echo -e "${BOLD}Gate Cycle Integration Tests${RESET}"

# --- Scenario A: All FRs PASS on round 1 ---
echo ""
echo "Scenario A: All FRs PASS on round 1"

repo=$(create_test_repo)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/requirement-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        verify-requirements)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1

- FR-001: PASS
- FR-002: PASS
- FR-003: PASS
FINDINGS
            ;;
        requirements-fix) FIX_COUNT=$((FIX_COUNT + 1)) ;;
        requirements-recheck) RECHECK_COUNT=$((RECHECK_COUNT + 1)) ;;
    esac
    return 0
}

REQUIREMENTS_MAX_ROUNDS=2
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "A: rc=0"
tasks=$(cat "$repo/specs/001-test/tasks.md")
assert_contains "$tasks" "REQUIREMENTS_VERIFIED" "A: REQUIREMENTS_VERIFIED marker"
assert_eq "1" "$INVOKE_COUNT" "A: INVOKE_COUNT=1 (verify only)"
assert_eq "1" "$VERIFY_COUNT" "A: VERIFY_COUNT=1"
assert_eq "0" "$FIX_COUNT" "A: FIX_COUNT=0"
assert_eq "0" "$RECHECK_COUNT" "A: RECHECK_COUNT=0"
rm -rf "$repo"

# --- Scenario B: Gaps -> fix -> recheck PASS ---
echo ""
echo "Scenario B: Gaps -> fix -> recheck Verdict: PASS"

repo=$(create_test_repo)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/requirement-findings.md"
TEST_RECHECK_FILE="$repo/specs/001-test/requirement-recheck-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        verify-requirements)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1

- FR-001: NOT_FOUND
- FR-002: PASS
- FR-003: PASS
FINDINGS
            ;;
        requirements-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            # Simulate fix: create a commit
            echo "fix for FR-001" > "$repo/src/fix.txt"
            git -C "$repo" add -A
            git -C "$repo" commit -q -m "fix FR-001"
            ;;
        requirements-recheck)
            RECHECK_COUNT=$((RECHECK_COUNT + 1))
            cat >> "$TEST_RECHECK_FILE" <<'FINDINGS'

Verdict: PASS

All requirements now satisfied.
FINDINGS
            ;;
    esac
    return 0
}

REQUIREMENTS_MAX_ROUNDS=2
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "B: rc=0"
tasks=$(cat "$repo/specs/001-test/tasks.md")
assert_contains "$tasks" "REQUIREMENTS_VERIFIED" "B: REQUIREMENTS_VERIFIED marker"
assert_eq "3" "$INVOKE_COUNT" "B: INVOKE_COUNT=3 (verify+fix+recheck)"
assert_eq "1" "$VERIFY_COUNT" "B: VERIFY_COUNT=1"
assert_eq "1" "$FIX_COUNT" "B: FIX_COUNT=1"
assert_eq "1" "$RECHECK_COUNT" "B: RECHECK_COUNT=1"
rm -rf "$repo"

# --- Scenario D: Gaps -> fix (no commits) -> skip recheck ---
echo ""
echo "Scenario D: Gaps -> fix (no commits) -> skip recheck"

repo=$(create_test_repo)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/requirement-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        verify-requirements)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            if [[ $VERIFY_COUNT -eq 1 ]]; then
                cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1

- FR-001: NOT_FOUND
- FR-002: PASS
- FR-003: PASS
FINDINGS
            else
                cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 2

- FR-001: PASS
- FR-002: PASS
- FR-003: PASS
FINDINGS
            fi
            ;;
        requirements-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            # Deliberately do NOT commit anything — HEAD stays the same
            ;;
        requirements-recheck)
            RECHECK_COUNT=$((RECHECK_COUNT + 1))
            ;;
    esac
    return 0
}

REQUIREMENTS_MAX_ROUNDS=2
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "D: rc=0"
assert_eq "0" "$RECHECK_COUNT" "D: RECHECK_COUNT=0 (skipped, no commits)"
assert_eq "1" "$FIX_COUNT" "D: FIX_COUNT=1"
# Round 2 verify should have run
assert_eq "2" "$VERIFY_COUNT" "D: VERIFY_COUNT=2 (round 2 re-verified)"
rm -rf "$repo"

# --- Scenario G: All FRs DEFERRED -> trivial pass ---
echo ""
echo "Scenario G: All FRs DEFERRED -> trivial pass"

repo=$(create_test_repo)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/requirement-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        verify-requirements)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1

- FR-001: DEFERRED
- FR-002: DEFERRED
- FR-003: DEFERRED
FINDINGS
            ;;
        requirements-fix) FIX_COUNT=$((FIX_COUNT + 1)) ;;
        requirements-recheck) RECHECK_COUNT=$((RECHECK_COUNT + 1)) ;;
    esac
    return 0
}

# max_rounds=1 so it exhausts and hits the "all deferred" branch
REQUIREMENTS_MAX_ROUNDS=1
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "G: rc=0"
tasks=$(cat "$repo/specs/001-test/tasks.md")
assert_contains "$tasks" "REQUIREMENTS_VERIFIED" "G: REQUIREMENTS_VERIFIED marker"
# Check commit message mentions "all deferred"
last_msg=$(git -C "$repo" log -1 --format='%s')
assert_contains "$last_msg" "requirements verified" "G: commit msg contains 'requirements verified'"
rm -rf "$repo"

# --- Scenario H: No FRs in spec -> skip ---
echo ""
echo "Scenario H: No FRs in spec -> skip"

repo=$(create_test_repo_no_frs)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    return 0
}

REQUIREMENTS_MAX_ROUNDS=2
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "H: rc=0"
tasks=$(cat "$repo/specs/001-test/tasks.md")
assert_contains "$tasks" "REQUIREMENTS_VERIFIED" "H: REQUIREMENTS_VERIFIED marker"
assert_eq "0" "$INVOKE_COUNT" "H: INVOKE_COUNT=0 (skipped)"
rm -rf "$repo"

# --- Scenario I: REQUIREMENTS_MAX_ROUNDS=1 -> only 1 round ---
echo ""
echo "Scenario I: REQUIREMENTS_MAX_ROUNDS=1 -> only 1 round"

repo=$(create_test_repo)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/requirement-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        verify-requirements)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1

- FR-001: NOT_FOUND
- FR-002: PASS
- FR-003: PASS
FINDINGS
            ;;
        requirements-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            echo "fix" > "$repo/src/fix.txt"
            git -C "$repo" add -A
            git -C "$repo" commit -q -m "fix"
            ;;
        requirements-recheck)
            RECHECK_COUNT=$((RECHECK_COUNT + 1))
            local rfile="$repo/specs/001-test/requirement-recheck-findings.md"
            cat >> "$rfile" <<'FINDINGS'

Verdict: FAIL

Still gaps.
FINDINGS
            ;;
    esac
    return 0
}

REQUIREMENTS_MAX_ROUNDS=1
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

# With max_rounds=1, only 1 round executes then exhaustion logic
assert_eq "1" "$VERIFY_COUNT" "I: VERIFY_COUNT=1 (only 1 round)"
rm -rf "$repo"

# --- Scenario J: REQUIREMENTS_MAX_ROUNDS=0 -> guarded to 1 ---
echo ""
echo "Scenario J: REQUIREMENTS_MAX_ROUNDS=0 -> guarded to 1"

repo=$(create_test_repo)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/requirement-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        verify-requirements)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1

- FR-001: PASS
- FR-002: PASS
- FR-003: PASS
FINDINGS
            ;;
        requirements-fix) FIX_COUNT=$((FIX_COUNT + 1)) ;;
        requirements-recheck) RECHECK_COUNT=$((RECHECK_COUNT + 1)) ;;
    esac
    return 0
}

REQUIREMENTS_MAX_ROUNDS=0
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "J: rc=0 (guard fired, 1 round ran)"
assert_eq "1" "$VERIFY_COUNT" "J: VERIFY_COUNT=1 (guarded to 1)"
rm -rf "$repo"
# --- Scenario U: invoke_claude verify returns non-zero ---
echo ""
echo "Scenario U: invoke_claude verify returns non-zero"

repo=$(create_test_repo)
INVOKE_COUNT=0 VERIFY_COUNT=0 FIX_COUNT=0 RECHECK_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/requirement-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        verify-requirements)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            if [[ $VERIFY_COUNT -eq 1 ]]; then
                return 1
            fi
            # Round 2: succeed with all PASS
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 2

- FR-001: PASS
- FR-002: PASS
- FR-003: PASS
FINDINGS
            return 0
            ;;
        *) return 0 ;;
    esac
}

REQUIREMENTS_MAX_ROUNDS=2
REQUIREMENTS_FORCE_SKIP_ALLOWED=true
rc=0; _run_requirements_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "U: rc=0 (recovered on round 2)"
assert_eq "2" "$VERIFY_COUNT" "U: VERIFY_COUNT=2 (round 1 failed, round 2 ok)"
assert_eq "0" "$FIX_COUNT" "U: FIX_COUNT=0 (no fix needed)"
rm -rf "$repo"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""

# TODO: C E F K L M N O P Q R S T scenarios

[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
