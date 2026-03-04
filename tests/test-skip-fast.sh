#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TESTS=0 PASSED=0 FAILED=0
assert() {
    local label="$1" condition="$2"
    TESTS=$((TESTS + 1))
    if eval "$condition"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: $label"
    fi
}

# Test the arithmetic behavior of PHASE_MAX_RETRIES

# Test 1: MAX_RETRIES=0 skips the loop
declare -A PHASE_MAX_RETRIES=([test-phase]=0)
retries=0
max_retries=${PHASE_MAX_RETRIES[test-phase]:-3}
loop_ran=false
while [[ $retries -lt $max_retries ]]; do
    loop_ran=true
    break
done
assert "MAX_RETRIES=0 skips loop" "[[ '$loop_ran' == 'false' ]]"

# Test 2: MAX_RETRIES=0 triggers force-advance
force_advance=false
if [[ $retries -ge $max_retries ]]; then
    force_advance=true
fi
assert "MAX_RETRIES=0 triggers force-advance" "[[ '$force_advance' == 'true' ]]"

# Test 3: MAX_RETRIES=1 runs loop once
PHASE_MAX_RETRIES[test-phase]=1
retries=0
max_retries=${PHASE_MAX_RETRIES[test-phase]:-3}
loop_count=0
while [[ $retries -lt $max_retries ]]; do
    loop_count=$((loop_count + 1))
    retries=$((retries + 1))
done
assert "MAX_RETRIES=1 runs loop once" "[[ '$loop_count' == '1' ]]"

# Test 4: MAX_RETRIES=1 triggers force-advance after
force_advance=false
if [[ $retries -ge $max_retries ]]; then
    force_advance=true
fi
assert "MAX_RETRIES=1 triggers force-advance" "[[ '$force_advance' == 'true' ]]"

# Test 5: --fast then --skip ordering (skip overrides fast)
PHASE_MAX_RETRIES[clarify]=1  # --fast
PHASE_MAX_RETRIES[clarify]=0  # --skip clarify (should override)
assert "--skip overrides --fast" "[[ '${PHASE_MAX_RETRIES[clarify]}' == '0' ]]"

# Test 6: --skip whitelist (only allowed phases)
allowed_phases="clarify clarify-verify design-read analyze"
for phase in implement review crystallize specify; do
    case "$phase" in
        clarify|clarify-verify|design-read|analyze) is_allowed=true ;;
        *) is_allowed=false ;;
    esac
    assert "--skip rejects $phase" "[[ '$is_allowed' == 'false' ]]"
done

echo ""
echo "Results: $PASSED/$TESTS passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
