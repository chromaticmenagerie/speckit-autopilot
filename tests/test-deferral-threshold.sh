#!/usr/bin/env bash
# test-deferral-threshold.sh — Graduated deferral threshold tests
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
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ✓ $desc"; PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (expected to contain '$needle')"; FAIL=$((FAIL + 1))
    fi
}

# ─── Extract the threshold block from source ────────────────────────────────
# We simulate the graduated threshold logic in isolation

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Simulates the graduated threshold logic (mirrors src/autopilot.sh)
run_threshold() {
    local consecutive_deferred="$1"
    local repo_root="$TMPDIR_ROOT/repo"
    local epic_num="001"
    local stuck_phase="2"
    local retries=3
    local spec_dir="$repo_root/specs/001-test"
    mkdir -p "$spec_dir" "$repo_root/.specify/logs"

    local output=""
    log() { output+="[$1] $2 "; }

    # Mirror the graduated logic from autopilot.sh
    if [[ $consecutive_deferred -ge 5 ]]; then
        log WARN "5 consecutive phases deferred — force-forward, logging and resetting counter"
        local defer_log="$repo_root/.specify/logs/deferred-phases.log"
        mkdir -p "$(dirname "$defer_log")"
        printf '%s  FORCE-FORWARD  epic=%s  phase=%s  consecutive=%d  retries=%d\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$epic_num" "$stuck_phase" "$consecutive_deferred" "$retries" \
            >> "$defer_log"
        local skip_md="$spec_dir/skipped-findings.md"
        {
            printf '## Force-Forward at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '- Phase: %s\n' "$stuck_phase"
            printf '- Consecutive deferrals: %d\n' "$consecutive_deferred"
            printf '- Implement retries: %d\n\n' "$retries"
        } >> "$skip_md"
        consecutive_deferred=0
    elif [[ $consecutive_deferred -eq 4 ]]; then
        log WARN "4 consecutive phases deferred — force-forward imminent"
    elif [[ $consecutive_deferred -eq 3 ]]; then
        log WARN "3 consecutive phases deferred — continuing"
    fi

    echo "OUTPUT:$output"
    echo "COUNTER:$consecutive_deferred"
    echo "DEFER_LOG:$(cat "$repo_root/.specify/logs/deferred-phases.log" 2>/dev/null || echo '')"
    echo "SKIP_MD:$(cat "$spec_dir/skipped-findings.md" 2>/dev/null || echo '')"
}

# ─── Tests ──────────────────────────────────────────────────────────────────
echo "=== Graduated Deferral Threshold Tests ==="

# Test 1: consecutive_deferred=2 → silent (no log output)
echo "Test 1: consecutive_deferred=2 → silent"
result=$(run_threshold 2)
output_line=$(echo "$result" | grep "^OUTPUT:" | sed 's/^OUTPUT://')
assert_eq "deferred=2 produces no warning" "" "$output_line"

# Test 2: consecutive_deferred=3 → WARN logged
echo "Test 2: consecutive_deferred=3 → WARN"
result=$(run_threshold 3)
output_line=$(echo "$result" | grep "^OUTPUT:" | sed 's/^OUTPUT://')
assert_contains "deferred=3 logs warning" "3 consecutive phases deferred" "$output_line"

# Test 3: consecutive_deferred=4 → louder WARN
echo "Test 3: consecutive_deferred=4 → louder WARN"
result=$(run_threshold 4)
output_line=$(echo "$result" | grep "^OUTPUT:" | sed 's/^OUTPUT://')
assert_contains "deferred=4 logs force-forward imminent" "force-forward imminent" "$output_line"

# Test 4: consecutive_deferred=5 → force-forward, logs written
echo "Test 4: consecutive_deferred=5 → force-forward"
result=$(run_threshold 5)
output_line=$(echo "$result" | grep "^OUTPUT:" | sed 's/^OUTPUT://')
assert_contains "deferred=5 logs force-forward" "force-forward" "$output_line"

defer_log_line=$(echo "$result" | grep "^DEFER_LOG:" | sed 's/^DEFER_LOG://')
assert_contains "deferred-phases.log written" "FORCE-FORWARD" "$defer_log_line"

skip_md_line=$(echo "$result" | grep "^SKIP_MD:" | sed 's/^SKIP_MD://')
assert_contains "skipped-findings.md written" "Force-Forward" "$skip_md_line"

# Test 5: counter resets after force-forward at 5
echo "Test 5: counter resets after force-forward"
counter_line=$(echo "$result" | grep "^COUNTER:" | sed 's/^COUNTER://')
assert_eq "counter resets to 0 after force-forward" "0" "$counter_line"

# ─── Test 6: Source no longer has hard halt ──────────────────────────────────
echo "Test 6: no hard halt in source"
halt_count=$(grep -c 'consecutive phases deferred.*stopping' "$SRC_DIR/autopilot.sh" || true)
assert_eq "no hard-halt on consecutive deferrals in source" "0" "$halt_count"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
