#!/usr/bin/env bash
# test-full-default-flip.sh — Verify all 7 gate variables default to true,
# --strict sets all to false, and STRICT_MODE reapply block exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== test-full-default-flip ==="

# ── 1. Verify 7 gate variable defaults are true ──

# 1a. ALLOW_DEFERRED defaults to true in autopilot.sh
if grep -q 'ALLOW_DEFERRED="\${ALLOW_DEFERRED:-true}"' "$SRC_DIR/autopilot.sh"; then
    pass "ALLOW_DEFERRED defaults to true"
else
    fail "ALLOW_DEFERRED does not default to true"
fi

# 1b. SECURITY_FORCE_SKIP_ALLOWED defaults to true
if grep -q 'SECURITY_FORCE_SKIP_ALLOWED="\${SECURITY_FORCE_SKIP_ALLOWED:-true}"' "$SRC_DIR/autopilot.sh"; then
    pass "SECURITY_FORCE_SKIP_ALLOWED defaults to true"
else
    fail "SECURITY_FORCE_SKIP_ALLOWED does not default to true"
fi

# 1c. REQUIREMENTS_FORCE_SKIP_ALLOWED defaults to true
if grep -q 'REQUIREMENTS_FORCE_SKIP_ALLOWED="\${REQUIREMENTS_FORCE_SKIP_ALLOWED:-true}"' "$SRC_DIR/autopilot.sh"; then
    pass "REQUIREMENTS_FORCE_SKIP_ALLOWED defaults to true"
else
    fail "REQUIREMENTS_FORCE_SKIP_ALLOWED does not default to true"
fi

# 1d. CI_FORCE_SKIP_ALLOWED defaults to true
if grep -q 'CI_FORCE_SKIP_ALLOWED="\${CI_FORCE_SKIP_ALLOWED:-true}"' "$SRC_DIR/autopilot-gates.sh"; then
    pass "CI_FORCE_SKIP_ALLOWED defaults to true"
else
    fail "CI_FORCE_SKIP_ALLOWED does not default to true"
fi

# 1e. FORCE_ADVANCE_ON_REVIEW_STALL defaults to true (in autopilot-lib.sh)
if grep -q 'FORCE_ADVANCE_ON_REVIEW_STALL="\${FORCE_ADVANCE_ON_REVIEW_STALL:-true}"' "$SRC_DIR/autopilot-lib.sh"; then
    pass "FORCE_ADVANCE_ON_REVIEW_STALL defaults to true"
else
    fail "FORCE_ADVANCE_ON_REVIEW_STALL does not default to true"
fi

# 1f. FORCE_ADVANCE_ON_DIMINISHING_RETURNS defaults to true
if grep -q 'FORCE_ADVANCE_ON_DIMINISHING_RETURNS="\${FORCE_ADVANCE_ON_DIMINISHING_RETURNS:-true}"' "$SRC_DIR/autopilot-lib.sh"; then
    pass "FORCE_ADVANCE_ON_DIMINISHING_RETURNS defaults to true"
else
    fail "FORCE_ADVANCE_ON_DIMINISHING_RETURNS does not default to true"
fi

# 1g. FORCE_ADVANCE_ON_REVIEW_ERROR defaults to true
if grep -q 'FORCE_ADVANCE_ON_REVIEW_ERROR="\${FORCE_ADVANCE_ON_REVIEW_ERROR:-true}"' "$SRC_DIR/autopilot-lib.sh"; then
    pass "FORCE_ADVANCE_ON_REVIEW_ERROR defaults to true"
else
    fail "FORCE_ADVANCE_ON_REVIEW_ERROR does not default to true"
fi

# ── 2. Verify --strict sets all gates to false + cascade limit to 0 ──

# Check the strict reapply block exists in autopilot.sh
strict_block=$(sed -n '/Strict mode: override all permissive/,/log INFO "Strict mode/p' "$SRC_DIR/autopilot.sh")

if [[ -z "$strict_block" ]]; then
    fail "--strict reapply block not found in autopilot.sh"
else
    pass "--strict reapply block exists"

    # Verify each variable is set to false/0 inside the block
    for var in ALLOW_DEFERRED FORCE_ADVANCE_ON_REVIEW_STALL FORCE_ADVANCE_ON_DIMINISHING_RETURNS \
               FORCE_ADVANCE_ON_REVIEW_ERROR SECURITY_FORCE_SKIP_ALLOWED \
               REQUIREMENTS_FORCE_SKIP_ALLOWED CI_FORCE_SKIP_ALLOWED; do
        if echo "$strict_block" | grep -q "${var}=false"; then
            pass "--strict sets $var=false"
        else
            fail "--strict does not set $var=false"
        fi
    done

    if echo "$strict_block" | grep -q "FORCE_SKIP_CASCADE_LIMIT=0"; then
        pass "--strict sets FORCE_SKIP_CASCADE_LIMIT=0"
    else
        fail "--strict does not set FORCE_SKIP_CASCADE_LIMIT=0"
    fi
fi

# ── 3. Verify --strict flag is wired in parse_args ──

if grep -q -- '--strict).*STRICT_MODE=true' "$SRC_DIR/autopilot.sh"; then
    pass "--strict flag wired in parse_args"
else
    fail "--strict flag not wired in parse_args"
fi

# ── 4. Verify STRICT_MODE default is false ──

if grep -q 'STRICT_MODE=false' "$SRC_DIR/autopilot.sh"; then
    pass "STRICT_MODE defaults to false"
else
    fail "STRICT_MODE default not found"
fi

# ── 5. Verify --allow-* flags are deprecated (log WARN, no assignment) ──

for flag in "allow-deferred" "allow-security-skip" "allow-requirements-skip"; do
    if grep -A1 -- "--${flag})" "$SRC_DIR/autopilot.sh" | grep -q 'log WARN.*deprecated'; then
        pass "--${flag} logs deprecation warning"
    else
        fail "--${flag} does not log deprecation warning"
    fi
done

# ── 6. Verify project.env template no longer has individual FORCE_ADVANCE vars ──

TEMPLATE_SRC="$SRC_DIR/autopilot-detect-tools.sh"
if grep -q 'FORCE_ADVANCE_ON_REVIEW_STALL=' "$TEMPLATE_SRC"; then
    fail "project.env template still has FORCE_ADVANCE_ON_REVIEW_STALL"
else
    pass "project.env template cleaned of individual FORCE_ADVANCE vars"
fi

if grep -q 'All gate variables default to true' "$TEMPLATE_SRC"; then
    pass "project.env template has consolidated gate comment"
else
    fail "project.env template missing consolidated gate comment"
fi

# ── 7. Verify help text includes --strict ──

if grep -q -- '--strict.*Halt on all gate' "$SRC_DIR/autopilot.sh"; then
    pass "Help text includes --strict"
else
    fail "Help text missing --strict"
fi

# ── 8. Verify help text marks --allow-* as deprecated ──

if grep -q 'Deprecated' "$SRC_DIR/autopilot.sh" && grep -q -- '--allow-deferred' "$SRC_DIR/autopilot.sh"; then
    pass "Help text marks --allow-* as deprecated"
else
    fail "Help text does not mark --allow-* as deprecated"
fi

# ── Summary ──
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
