#!/usr/bin/env bash
# test-security-gate-integration.sh — Integration tests for _run_security_gate()
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

log() { :; }
_emit_event() { :; }
_accumulate_phase_cost() { :; }
prompt_security_review() { echo "review prompt stub"; }
prompt_security_fix() { echo "fix prompt stub"; }
prompt_security_verify() { echo "verify prompt stub"; }
# invoke_claude will be redefined per-test
invoke_claude() { return 0; }

source "$SRC_DIR/autopilot-gates.sh"

# ─── Helper: create test repo ───────────────────────────────────────────────

create_test_repo() {
    local repo=$(mktemp -d)
    git init -q "$repo"
    git -C "$repo" config user.email "test@test"
    git -C "$repo" config user.name "Test"
    git -C "$repo" commit --allow-empty -m "init" -q
    mkdir -p "$repo/specs/001-test"
    echo "- [x] Task 1" > "$repo/specs/001-test/tasks.md"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "spec"
    echo "$repo"
}

# ─── Section 4: Verdict Parsing Tests ────────────────────────────────────────

echo ""
echo -e "${BOLD}Verdict Parsing Tests${RESET}"

parse_verdict() {
    local file="$1"
    local v
    v=$(grep -i '^Verdict:' "$file" | tail -1 | awk '{print toupper($2)}')
    echo "${v:-UNKNOWN}"
}

# 1. Review FAIL + verify PASS
tmp=$(mktemp)
printf 'Verdict: FAIL\nVerdict: PASS\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "1: review FAIL + verify PASS → PASS"
rm -f "$tmp"

# 2. No Verdict line
tmp=$(mktemp)
printf '# Security Review\nNo issues.\n' > "$tmp"
assert_eq "UNKNOWN" "$(parse_verdict "$tmp")" "2: no Verdict line → UNKNOWN"
rm -f "$tmp"

# 3. Lowercase
tmp=$(mktemp)
printf 'verdict: pass\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "3: lowercase → PASS"
rm -f "$tmp"

# 4. Extra whitespace
tmp=$(mktemp)
printf 'Verdict:  PASS   \n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "4: extra whitespace → PASS"
rm -f "$tmp"

# 5. PARTIAL
tmp=$(mktemp)
printf 'Verdict: PARTIAL\n' > "$tmp"
assert_eq "PARTIAL" "$(parse_verdict "$tmp")" "5: PARTIAL → PARTIAL"
rm -f "$tmp"

# 6. Indented (^ anchor fails)
tmp=$(mktemp)
printf '    Verdict: PASS\n' > "$tmp"
assert_eq "UNKNOWN" "$(parse_verdict "$tmp")" "6: indented → UNKNOWN (^ anchor)"
rm -f "$tmp"

# 7. Trailing text
tmp=$(mktemp)
printf 'Verdict: PASS - all clear\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "7: trailing text → PASS"
rm -f "$tmp"

# 8. Empty file
tmp=$(mktemp)
: > "$tmp"
assert_eq "UNKNOWN" "$(parse_verdict "$tmp")" "8: empty file → UNKNOWN"
rm -f "$tmp"

# 9. 3 rounds (FAIL, FAIL, PASS)
tmp=$(mktemp)
printf 'Verdict: FAIL\nVerdict: FAIL\nVerdict: PASS\n' > "$tmp"
assert_eq "PASS" "$(parse_verdict "$tmp")" "9: 3 rounds FAIL,FAIL,PASS → PASS"
rm -f "$tmp"

# 10. No value after Verdict:
tmp=$(mktemp)
printf 'Verdict:\n' > "$tmp"
assert_eq "UNKNOWN" "$(parse_verdict "$tmp")" "10: Verdict: alone → UNKNOWN"
rm -f "$tmp"

# ─── Section 5: Gate Cycle Integration Tests ─────────────────────────────────

echo ""
echo -e "${BOLD}Gate Cycle Integration Tests${RESET}"

# --- Test A: Clean pass ---
echo ""
echo "Test A: Clean pass"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    if [[ "$phase" == "security-review" ]]; then
        REVIEW_COUNT=$((REVIEW_COUNT + 1))
        cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1 (1/2)

Verdict: PASS

No findings.
FINDINGS
    fi
    return 0
}

SECURITY_MAX_ROUNDS=2
SECURITY_FORCE_SKIP_ALLOWED=false
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "A: rc=0"
tasks=$(cat "$repo/specs/001-test/tasks.md")
assert_contains "$tasks" "SECURITY_REVIEWED" "A: SECURITY_REVIEWED marker"
assert_eq "1" "$INVOKE_COUNT" "A: INVOKE_COUNT=1"
assert_eq "1" "$REVIEW_COUNT" "A: REVIEW_COUNT=1"
assert_eq "0" "$FIX_COUNT" "A: FIX_COUNT=0"
assert_eq "0" "$VERIFY_COUNT" "A: VERIFY_COUNT=0"
rm -rf "$repo"

# --- Test B: Fix + verify pass ---
echo ""
echo "Test B: Fix + verify pass"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        security-review)
            REVIEW_COUNT=$((REVIEW_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1 (1/2)

Verdict: FAIL

### 1. Missing input validation
- **Severity**: MEDIUM
- **Category**: input-validation
- **File**: src/handler.go:42
- **Auto-fixable**: yes
FINDINGS
            ;;
        security-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            ;;
        security-verify)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

### Verify Cycle 1

Verdict: PASS

All findings resolved.
FINDINGS
            ;;
    esac
    return 0
}

SECURITY_MAX_ROUNDS=2
SECURITY_FORCE_SKIP_ALLOWED=false
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "B: rc=0"
tasks=$(cat "$repo/specs/001-test/tasks.md")
assert_contains "$tasks" "SECURITY_REVIEWED" "B: SECURITY_REVIEWED marker"
assert_eq "3" "$INVOKE_COUNT" "B: INVOKE_COUNT=3"
assert_eq "1" "$REVIEW_COUNT" "B: REVIEW_COUNT=1"
assert_eq "1" "$FIX_COUNT" "B: FIX_COUNT=1"
assert_eq "1" "$VERIFY_COUNT" "B: VERIFY_COUNT=1"
rm -rf "$repo"

# --- Test C: LOW deadlock resolved by verify ---
echo ""
echo "Test C: LOW deadlock resolved by verify"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        security-review)
            REVIEW_COUNT=$((REVIEW_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1 (1/2)

Verdict: FAIL

### 1. Missing input validation
- **Severity**: MEDIUM
- **Category**: input-validation
- **File**: src/handler.go:42
- **Auto-fixable**: yes

### 2. Weak default config
- **Severity**: LOW
- **Category**: configuration
- **File**: config/default.yaml:10
- **Auto-fixable**: yes

### 3. Missing rate limit header
- **Severity**: LOW
- **Category**: rate-limiting
- **File**: src/middleware.go:15
- **Auto-fixable**: no
FINDINGS
            ;;
        security-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            ;;
        security-verify)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

### Verify Cycle 1

Verdict: PASS

All findings resolved or accepted.
FINDINGS
            ;;
    esac
    return 0
}

SECURITY_MAX_ROUNDS=2
SECURITY_FORCE_SKIP_ALLOWED=false
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "C: rc=0"
assert_eq "3" "$INVOKE_COUNT" "C: INVOKE_COUNT=3 (1 cycle)"
rm -rf "$repo"

# --- Test D: LOW escape hatch (review-only LOWs) ---
echo ""
echo "Test D: LOW escape hatch (review-only LOWs)"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        security-review)
            REVIEW_COUNT=$((REVIEW_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1 (1/2)

Verdict: FAIL

### 1. Weak default config
- **Severity**: LOW
- **Category**: configuration
- **File**: config/default.yaml:10
- **Auto-fixable**: yes

### 2. Missing rate limit header
- **Severity**: LOW
- **Category**: rate-limiting
- **File**: src/middleware.go:15
- **Auto-fixable**: no
FINDINGS
            ;;
        security-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            ;;
        security-verify)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            ;;
    esac
    return 0
}

SECURITY_MAX_ROUNDS=2
SECURITY_FORCE_SKIP_ALLOWED=false
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "D: rc=0"
assert_eq "1" "$INVOKE_COUNT" "D: INVOKE_COUNT=1 (only review)"
assert_eq "0" "$FIX_COUNT" "D: FIX_COUNT=0"
assert_eq "0" "$VERIFY_COUNT" "D: VERIFY_COUNT=0"
rm -rf "$repo"

# --- Test E: Verify FAIL → cycle 2 review PASS ---
echo ""
echo "Test E: Verify FAIL → cycle 2 review PASS"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        security-review)
            REVIEW_COUNT=$((REVIEW_COUNT + 1))
            if [[ $REVIEW_COUNT -eq 1 ]]; then
                cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 1 (1/3)

Verdict: FAIL

### 1. SQL injection risk
- **Severity**: MEDIUM
- **Category**: injection
- **File**: src/db.go:88
- **Auto-fixable**: yes
FINDINGS
            else
                cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

## Round 2 (2/3)

Verdict: PASS

All issues resolved.
FINDINGS
            fi
            ;;
        security-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            ;;
        security-verify)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

### Verify Cycle 1

Verdict: FAIL

Fix incomplete — SQL injection still present.
FINDINGS
            ;;
    esac
    return 0
}

SECURITY_MAX_ROUNDS=3
SECURITY_FORCE_SKIP_ALLOWED=false
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "E: rc=0"
assert_eq "4" "$INVOKE_COUNT" "E: INVOKE_COUNT=4"
assert_eq "2" "$REVIEW_COUNT" "E: REVIEW_COUNT=2"
assert_eq "1" "$FIX_COUNT" "E: FIX_COUNT=1"
assert_eq "1" "$VERIFY_COUNT" "E: VERIFY_COUNT=1"
rm -rf "$repo"

# --- Test F: Max cycles exhausted + force-skip ---
echo ""
echo "Test F: Max cycles exhausted + force-skip"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        security-review)
            REVIEW_COUNT=$((REVIEW_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<FINDINGS

## Round $REVIEW_COUNT ($REVIEW_COUNT/2)

Verdict: FAIL

### 1. Unresolved XSS
- **Severity**: MEDIUM
- **Category**: xss
- **File**: src/render.go:12
- **Auto-fixable**: yes
FINDINGS
            ;;
        security-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            ;;
        security-verify)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

### Verify Cycle

Verdict: FAIL

XSS still present.
FINDINGS
            ;;
    esac
    return 0
}

SECURITY_MAX_ROUNDS=2
SECURITY_FORCE_SKIP_ALLOWED=true
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "0" "$rc" "F: rc=0"
tasks=$(cat "$repo/specs/001-test/tasks.md")
assert_contains "$tasks" "SECURITY_REVIEWED" "F: SECURITY_REVIEWED marker"
assert_contains "$tasks" "SECURITY_FORCE_SKIPPED" "F: SECURITY_FORCE_SKIPPED marker"
rm -rf "$repo"

# --- Test G: CRITICAL halts despite force-skip ---
echo ""
echo "Test G: CRITICAL halts despite force-skip"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    local phase="$1"
    case "$phase" in
        security-review)
            REVIEW_COUNT=$((REVIEW_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<FINDINGS

## Round $REVIEW_COUNT ($REVIEW_COUNT/2)

Verdict: FAIL

### 1. Hardcoded credentials
- **Severity**: CRITICAL
- **Category**: secrets
- **File**: src/config.go:5
- **Auto-fixable**: yes
FINDINGS
            ;;
        security-fix)
            FIX_COUNT=$((FIX_COUNT + 1))
            ;;
        security-verify)
            VERIFY_COUNT=$((VERIFY_COUNT + 1))
            cat >> "$TEST_FINDINGS_FILE" <<'FINDINGS'

### Verify Cycle

Verdict: FAIL

Critical finding still present.

### 1. Hardcoded credentials
- **Severity**: CRITICAL
- **Category**: secrets
- **File**: src/config.go:5
FINDINGS
            ;;
    esac
    return 0
}

SECURITY_MAX_ROUNDS=2
SECURITY_FORCE_SKIP_ALLOWED=true
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "1" "$rc" "G: rc=1 (halted)"
tasks=$(cat "$repo/specs/001-test/tasks.md")
if [[ "$tasks" != *"SECURITY_REVIEWED"* ]]; then
    pass "G: no SECURITY_REVIEWED marker"
else
    fail "G: no SECURITY_REVIEWED marker (found it)"
fi
rm -rf "$repo"

# --- Test H: Resume guard re-halts ---
echo ""
echo "Test H: Resume guard re-halts"

repo=$(create_test_repo)
INVOKE_COUNT=0 REVIEW_COUNT=0 FIX_COUNT=0 VERIFY_COUNT=0
TEST_FINDINGS_FILE="$repo/specs/001-test/security-findings.md"

# Pre-write SECURITY_FORCE_SKIPPED but NOT SECURITY_REVIEWED
echo "" >> "$repo/specs/001-test/tasks.md"
echo "<!-- SECURITY_FORCE_SKIPPED -->" >> "$repo/specs/001-test/tasks.md"
git -C "$repo" add -A && git -C "$repo" commit -q -m "pre-halt"

invoke_claude() {
    INVOKE_COUNT=$((INVOKE_COUNT + 1))
    return 0
}

SECURITY_MAX_ROUNDS=2
SECURITY_FORCE_SKIP_ALLOWED=false
SECURITY_MIN_SEVERITY_TO_HALT=HIGH
rc=0; _run_security_gate "$repo" "001" "001-test" "Test Feature" "" || rc=$?

assert_eq "1" "$rc" "H: rc=1 (re-halts)"
assert_eq "0" "$INVOKE_COUNT" "H: INVOKE_COUNT=0 (gate never runs)"
rm -rf "$repo"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
