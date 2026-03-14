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

log() { :; }
source "$REPO_ROOT/src/autopilot-gates.sh"

# ─── Structural checks ──────────────────────────────────────────────────
grep -q '_classify_security_severity()' "$GATES_FILE" && pass "_classify_security_severity defined" || fail "_classify_security_severity defined"

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

# ─── _classify_security_severity_from_string tests ─────────────────────

# Structural: function exists in source
grep -q '_classify_security_severity_from_string()' "$GATES_FILE" && pass "_classify_security_severity_from_string defined" || fail "_classify_security_severity_from_string defined"

# Mixed severities via string
mixed_str="- **Severity**: CRITICAL — SQL injection
- **Severity**: HIGH — Missing rate limit
- **Severity**: MEDIUM — Verbose errors
- **Severity**: LOW — Missing headers
- **Severity**: HIGH — Open redirect"
result_s=$(_classify_security_severity_from_string "$mixed_str")
[[ "$(echo "$result_s" | awk '{print $1}')" == "1" ]] && pass "String: 1 CRITICAL" || fail "String: 1 CRITICAL (got $(echo "$result_s" | awk '{print $1}'))"
[[ "$(echo "$result_s" | awk '{print $2}')" == "2" ]] && pass "String: 2 HIGH" || fail "String: 2 HIGH"
[[ "$(echo "$result_s" | awk '{print $3}')" == "1" ]] && pass "String: 1 MEDIUM" || fail "String: 1 MEDIUM"
[[ "$(echo "$result_s" | awk '{print $4}')" == "1" ]] && pass "String: 1 LOW" || fail "String: 1 LOW"

# Empty string
result_empty=$(_classify_security_severity_from_string "")
result_empty_clean=$(echo "$result_empty" | tr -s ' ' | xargs)
[[ "$result_empty_clean" == "0 0 0 0" ]] && pass "String empty: all zeros" || fail "String empty: all zeros (got: '$result_empty_clean')"

# LOW-only string
low_str="- **Severity**: LOW — Missing CSP
- **Severity**: LOW — No HSTS
- **Severity**: LOW — No X-Frame"
result_low=$(_classify_security_severity_from_string "$low_str")
low_c=$(echo "$result_low" | awk '{print $1}'); low_c=${low_c:-0}
low_h=$(echo "$result_low" | awk '{print $2}'); low_h=${low_h:-0}
low_l=$(echo "$result_low" | awk '{print $4}'); low_l=${low_l:-0}
(( low_c + low_h == 0 )) && pass "String LOW-only: crit+high == 0" || fail "String LOW-only: crit+high == 0"
[[ "$low_l" == "3" ]] && pass "String LOW-only: low count == 3" || fail "String LOW-only: low count == 3 (got '$low_l')"

# HIGH-only string
high_str="- **Severity**: HIGH — Auth bypass
- **Severity**: HIGH — SSRF"
result_high=$(_classify_security_severity_from_string "$high_str")
high_c=$(echo "$result_high" | awk '{print $1}'); high_c=${high_c:-0}
high_h=$(echo "$result_high" | awk '{print $2}'); high_h=${high_h:-0}
high_m=$(echo "$result_high" | awk '{print $3}'); high_m=${high_m:-0}
high_lo=$(echo "$result_high" | awk '{print $4}'); high_lo=${high_lo:-0}
[[ "$high_c" == "0" ]] && pass "String HIGH-only: 0 critical" || fail "String HIGH-only: 0 critical"
[[ "$high_h" == "2" ]] && pass "String HIGH-only: 2 high" || fail "String HIGH-only: 2 high"
[[ "$high_m" == "0" ]] && pass "String HIGH-only: 0 medium" || fail "String HIGH-only: 0 medium"
[[ "$high_lo" == "0" ]] && pass "String HIGH-only: 0 low" || fail "String HIGH-only: 0 low"

# ─── Structural: MEDIUM elif case exists ───────────────────────────────
grep -q 'min_severity.*MEDIUM.*crit.*high.*med' "$GATES_FILE" && pass "MEDIUM elif case exists" || fail "MEDIUM elif case exists"

# ─── Structural: LOW escape hatch exists ───────────────────────────────
grep -q 'LOW escape hatch' "$GATES_FILE" && pass "LOW escape hatch comment exists" || fail "LOW escape hatch comment exists"
grep -q 'low_escape=true' "$GATES_FILE" && pass "low_escape assignment exists" || fail "low_escape assignment exists"

# ─── Structural: low_escape variable declared ─────────────────────────
grep -q 'local low_escape=false' "$GATES_FILE" && pass "low_escape variable declared" || fail "low_escape variable declared"
grep -q 'local low_count=0' "$GATES_FILE" && pass "low_count variable declared" || fail "low_count variable declared"

# ─── Structural: temp_findings_file rename (no shadowing) ─────────────
grep -q 'local temp_findings_file' "$GATES_FILE" && pass "temp_findings_file declared (no shadowing)" || fail "temp_findings_file declared (no shadowing)"

# ─── Structural: string-based severity on line 124 area ───────────────
grep -q '_classify_security_severity_from_string "\$latest_findings"' "$GATES_FILE" && pass "Uses string-based severity classifier" || fail "Uses string-based severity classifier"

# ─── Structural: log exit code on invoke_claude ───────────────────────
grep -q 'security-review exited with code' "$GATES_FILE" && pass "Logs exit code on invoke_claude failure" || fail "Logs exit code on invoke_claude failure"

# ─── Structural: conditional commit message ───────────────────────────
grep -q 'accepted LOW findings' "$GATES_FILE" && pass "Conditional commit msg for LOW escape" || fail "Conditional commit msg for LOW escape"

# ─── Structural: severity halt path exists ──────────────────────────────
grep -q 'halting regardless of SECURITY_FORCE_SKIP_ALLOWED' "$GATES_FILE" && pass "Severity check before force-skip exists" || fail "Severity check before force-skip exists"
grep -q 'SECURITY_MIN_SEVERITY_TO_HALT=.*HIGH' "$GATES_FILE" && pass "SECURITY_MIN_SEVERITY_TO_HALT default is HIGH" || fail "SECURITY_MIN_SEVERITY_TO_HALT default is HIGH"

# ─── Functional: _should_halt_on_severity ────────────────────────────

# HIGH threshold: CRITICAL findings → halt
rc=0; _should_halt_on_severity "HIGH" 1 0 0 0 || rc=$?
[[ $rc -eq 1 ]] && pass "halt: HIGH threshold, CRITICAL present → halt" || fail "halt: HIGH threshold, CRITICAL present → halt"

# HIGH threshold: HIGH findings → halt
rc=0; _should_halt_on_severity "HIGH" 0 2 0 0 || rc=$?
[[ $rc -eq 1 ]] && pass "halt: HIGH threshold, HIGH present → halt" || fail "halt: HIGH threshold, HIGH present → halt"

# HIGH threshold: only MEDIUM+LOW → allow
rc=0; _should_halt_on_severity "HIGH" 0 0 3 1 || rc=$?
[[ $rc -eq 0 ]] && pass "halt: HIGH threshold, only MED+LOW → allow" || fail "halt: HIGH threshold, only MED+LOW → allow"

# CRITICAL threshold: CRITICAL present → halt
rc=0; _should_halt_on_severity "CRITICAL" 1 0 0 0 || rc=$?
[[ $rc -eq 1 ]] && pass "halt: CRITICAL threshold, CRITICAL present → halt" || fail "halt: CRITICAL threshold, CRITICAL present → halt"

# CRITICAL threshold: only HIGH → allow
rc=0; _should_halt_on_severity "CRITICAL" 0 2 0 0 || rc=$?
[[ $rc -eq 0 ]] && pass "halt: CRITICAL threshold, only HIGH → allow" || fail "halt: CRITICAL threshold, only HIGH → allow"

# MEDIUM threshold: MEDIUM present → halt
rc=0; _should_halt_on_severity "MEDIUM" 0 0 1 0 || rc=$?
[[ $rc -eq 1 ]] && pass "halt: MEDIUM threshold, MEDIUM present → halt" || fail "halt: MEDIUM threshold, MEDIUM present → halt"

# MEDIUM threshold: only LOW → allow
rc=0; _should_halt_on_severity "MEDIUM" 0 0 0 2 || rc=$?
[[ $rc -eq 0 ]] && pass "halt: MEDIUM threshold, only LOW → allow" || fail "halt: MEDIUM threshold, only LOW → allow"

# LOW threshold: LOW present → halt
rc=0; _should_halt_on_severity "LOW" 0 0 0 1 || rc=$?
[[ $rc -eq 1 ]] && pass "halt: LOW threshold, LOW present → halt" || fail "halt: LOW threshold, LOW present → halt"

# ─── Functional: LOW escape hatch decision logic ────────────────────

# LOW-only findings + MIN!=LOW → would escape
SECURITY_MIN_SEVERITY_TO_HALT="HIGH"
esc_result=$(_classify_security_severity_from_string "- **Severity**: LOW — Missing CSP
- **Severity**: LOW — No HSTS")
read -r esc_c esc_h esc_m esc_l <<< "$esc_result"
(( esc_c + esc_h + esc_m == 0 )) && (( esc_l > 0 )) && [[ "$SECURITY_MIN_SEVERITY_TO_HALT" != "LOW" ]] && \
    pass "escape: LOW-only + MIN=HIGH → would escape" || fail "escape: LOW-only + MIN=HIGH → would escape"

# MEDIUM+LOW findings + MIN!=LOW → would NOT escape
SECURITY_MIN_SEVERITY_TO_HALT="HIGH"
esc_result=$(_classify_security_severity_from_string "- **Severity**: MEDIUM — Verbose errors
- **Severity**: LOW — Missing headers")
read -r esc_c esc_h esc_m esc_l <<< "$esc_result"
if (( esc_c + esc_h + esc_m == 0 )) && (( esc_l > 0 )) && [[ "$SECURITY_MIN_SEVERITY_TO_HALT" != "LOW" ]]; then
    fail "escape: MED+LOW + MIN=HIGH → should NOT escape"
else
    pass "escape: MED+LOW + MIN=HIGH → should NOT escape"
fi

# HIGH findings → would NOT escape
SECURITY_MIN_SEVERITY_TO_HALT="HIGH"
esc_result=$(_classify_security_severity_from_string "- **Severity**: HIGH — Auth bypass")
read -r esc_c esc_h esc_m esc_l <<< "$esc_result"
if (( esc_c + esc_h + esc_m == 0 )) && (( esc_l > 0 )) && [[ "$SECURITY_MIN_SEVERITY_TO_HALT" != "LOW" ]]; then
    fail "escape: HIGH findings → should NOT escape"
else
    pass "escape: HIGH findings → should NOT escape"
fi

# LOW-only findings + MIN=LOW → would NOT escape (hatch disabled)
SECURITY_MIN_SEVERITY_TO_HALT="LOW"
esc_result=$(_classify_security_severity_from_string "- **Severity**: LOW — Missing CSP")
read -r esc_c esc_h esc_m esc_l <<< "$esc_result"
if (( esc_c + esc_h + esc_m == 0 )) && (( esc_l > 0 )) && [[ "$SECURITY_MIN_SEVERITY_TO_HALT" != "LOW" ]]; then
    fail "escape: LOW-only + MIN=LOW → hatch disabled, should NOT escape"
else
    pass "escape: LOW-only + MIN=LOW → hatch disabled, should NOT escape"
fi

# Empty findings → would NOT escape
SECURITY_MIN_SEVERITY_TO_HALT="HIGH"
esc_result=$(_classify_security_severity_from_string "")
read -r esc_c esc_h esc_m esc_l <<< "$esc_result"
if (( esc_c + esc_h + esc_m == 0 )) && (( esc_l > 0 )) && [[ "$SECURITY_MIN_SEVERITY_TO_HALT" != "LOW" ]]; then
    fail "escape: empty findings → should NOT escape"
else
    pass "escape: empty findings → should NOT escape"
fi

# CRITICAL-only → would NOT escape
SECURITY_MIN_SEVERITY_TO_HALT="HIGH"
esc_result=$(_classify_security_severity_from_string "- **Severity**: CRITICAL — SQL injection")
read -r esc_c esc_h esc_m esc_l <<< "$esc_result"
if (( esc_c + esc_h + esc_m == 0 )) && (( esc_l > 0 )) && [[ "$SECURITY_MIN_SEVERITY_TO_HALT" != "LOW" ]]; then
    fail "escape: CRITICAL-only → should NOT escape"
else
    pass "escape: CRITICAL-only → should NOT escape"
fi

# Restore default
SECURITY_MIN_SEVERITY_TO_HALT="HIGH"

echo ""
echo -e "${BOLD}========================================${RESET}"
echo -e "  Tests: ${TESTS_RUN} total, ${GREEN}${TESTS_PASSED} passed${RESET}, ${RED}${TESTS_FAILED} failed${RESET}"
echo -e "${BOLD}========================================${RESET}"
echo ""
[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
