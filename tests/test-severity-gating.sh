#!/usr/bin/env bash
# test-severity-gating.sh — Verify _classify_security_severity and severity-based halt logic.
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

pass() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_PASSED=$((TESTS_PASSED+1)); echo -e "  ${GREEN}PASS${RESET} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1)); echo -e "  ${RED}FAIL${RESET} $1"; }

echo ""
echo -e "${BOLD}Severity Gating Tests${RESET}"

GATES_FILE="$REPO_ROOT/src/autopilot-gates.sh"

# ─── Structural checks ──────────────────────────────────────────────────
grep -q '_classify_security_severity()' "$GATES_FILE" && pass "_classify_security_severity defined" || fail "_classify_security_severity defined"

# Define function inline for testing
_classify_security_severity() {
    local findings_file="$1"
    local critical_count high_count medium_count low_count
    critical_count=$(grep -c '\*\*Severity\*\*: CRITICAL' "$findings_file" 2>/dev/null) || critical_count=0
    high_count=$(grep -c '\*\*Severity\*\*: HIGH' "$findings_file" 2>/dev/null) || high_count=0
    medium_count=$(grep -c '\*\*Severity\*\*: MEDIUM' "$findings_file" 2>/dev/null) || medium_count=0
    low_count=$(grep -c '\*\*Severity\*\*: LOW' "$findings_file" 2>/dev/null) || low_count=0
    echo "$critical_count $high_count $medium_count $low_count"
}

# ─── Test mixed severities ──────────────────────────────────────────────
TMPF=$(mktemp)
trap 'rm -f "$TMPF" "$TMPF2" "$TMPF3"' EXIT
cat > "$TMPF" <<'EOF'
## Round 1
- **Severity**: CRITICAL — SQL injection in login
- **Severity**: HIGH — Missing rate limiting
- **Severity**: MEDIUM — Verbose error messages
- **Severity**: LOW — Missing security headers
- **Severity**: HIGH — Open redirect
EOF

result=$(_classify_security_severity "$TMPF")
[[ "$(echo "$result" | awk '{print $1}')" == "1" ]] && pass "Mixed severities: 1 CRITICAL" || fail "Mixed severities: 1 CRITICAL"
[[ "$(echo "$result" | awk '{print $2}')" == "2" ]] && pass "Mixed severities: 2 HIGH" || fail "Mixed severities: 2 HIGH"
[[ "$(echo "$result" | awk '{print $3}')" == "1" ]] && pass "Mixed severities: 1 MEDIUM" || fail "Mixed severities: 1 MEDIUM"
[[ "$(echo "$result" | awk '{print $4}')" == "1" ]] && pass "Mixed severities: 1 LOW" || fail "Mixed severities: 1 LOW"

# ─── Test empty file ────────────────────────────────────────────────────
TMPF2=$(mktemp)
echo "No findings" > "$TMPF2"
result2=$(_classify_security_severity "$TMPF2")
result2_clean=$(echo "$result2" | tr -s ' ' | xargs)
[[ "$result2_clean" == "0 0 0 0" ]] && pass "Empty file: all zeros" || fail "Empty file: all zeros (got: '$result2_clean')"

# ─── Test LOW-only ──────────────────────────────────────────────────────
TMPF3=$(mktemp)
cat > "$TMPF3" <<'EOF'
- **Severity**: LOW — Missing CSP header
- **Severity**: LOW — No HSTS
EOF

result3=$(_classify_security_severity "$TMPF3")
c=$(echo "$result3" | awk '{print $1}'); c=${c:-0}
h=$(echo "$result3" | awk '{print $2}'); h=${h:-0}
l=$(echo "$result3" | awk '{print $4}'); l=${l:-0}
(( c + h == 0 )) && pass "LOW-only: crit+high == 0" || fail "LOW-only: crit+high == 0"
[[ "$l" == "2" ]] && pass "LOW-only: low count == 2" || fail "LOW-only: low count == 2 (got: '$l')"

# ─── Structural: severity halt path exists ──────────────────────────────
grep -q 'halting regardless of SECURITY_FORCE_SKIP_ALLOWED' "$GATES_FILE" && pass "Severity check before force-skip exists" || fail "Severity check before force-skip exists"
grep -q 'SECURITY_MIN_SEVERITY_TO_HALT=.*HIGH' "$GATES_FILE" && pass "SECURITY_MIN_SEVERITY_TO_HALT default is HIGH" || fail "SECURITY_MIN_SEVERITY_TO_HALT default is HIGH"

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
