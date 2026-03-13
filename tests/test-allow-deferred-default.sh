#!/usr/bin/env bash
# test-allow-deferred-default.sh — Verify ALLOW_DEFERRED defaults to true
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────
PASS=0 FAIL=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $desc"; PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (expected=$expected, got=$actual)"; FAIL=$((FAIL + 1))
    fi
}

# ─── Test 1: Source default is true ─────────────────────────────────────────
echo "=== ALLOW_DEFERRED Default Tests ==="

default_line=$(grep 'ALLOW_DEFERRED=' "$SRC_DIR/autopilot.sh" | head -1)
assert_eq "default line uses :- expansion" 'ALLOW_DEFERRED="${ALLOW_DEFERRED:-true}"' "$default_line"

# ─── Test 2: Env var not set → defaults to true ─────────────────────────────
(
    unset ALLOW_DEFERRED 2>/dev/null || true
    eval "$default_line"
    [[ "$ALLOW_DEFERRED" == "true" ]]
) && assert_eq "unset env → ALLOW_DEFERRED=true" "true" "true" \
  || assert_eq "unset env → ALLOW_DEFERRED=true" "true" "false"

# ─── Test 3: Env override to false still works ──────────────────────────────
(
    export ALLOW_DEFERRED=false
    eval 'ALLOW_DEFERRED="${ALLOW_DEFERRED:-true}"'
    [[ "$ALLOW_DEFERRED" == "false" ]]
) && assert_eq "ALLOW_DEFERRED=false env override preserved" "true" "true" \
  || assert_eq "ALLOW_DEFERRED=false env override preserved" "true" "false"

# ─── Test 4: --allow-deferred flag still parsed ─────────────────────────────
grep -q '\-\-allow-deferred.*ALLOW_DEFERRED=true' "$SRC_DIR/autopilot.sh" \
  && assert_eq "--allow-deferred flag still in parse_args" "true" "true" \
  || assert_eq "--allow-deferred flag still in parse_args" "true" "false"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
