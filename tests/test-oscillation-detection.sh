#!/usr/bin/env bash
# test-oscillation-detection.sh — Tests for oscillation detection (Item 12)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Harness ────────────────────────────────────────────────────────────
PASS=0 FAIL=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $desc"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $desc (expected='$expected', got='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Setup ───────────────────────────────────────────────────────────────────
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT
AUTOPILOT_LOG=""
BOLD="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM=""
log() { :; }

source "$SRC_DIR/common.sh" 2>/dev/null || true
source "$SRC_DIR/autopilot-lib.sh" 2>/dev/null || true

# ─── Tests ───────────────────────────────────────────────────────────────────
echo "== _file_hash consistency =="

# Test 1: Same file produces same hash
echo "Test 1: _file_hash returns consistent hash"
echo "hello world" > "$TMPDIR_ROOT/test.md"
h1=$(_file_hash "$TMPDIR_ROOT/test.md")
h2=$(_file_hash "$TMPDIR_ROOT/test.md")
assert_eq "same file same hash" "$h1" "$h2"

# Test 2: Different content produces different hash
echo "Test 2: _file_hash different content = different hash"
echo "different content" > "$TMPDIR_ROOT/test2.md"
h3=$(_file_hash "$TMPDIR_ROOT/test2.md")
if [[ "$h1" != "$h3" ]]; then
    echo "  ✓ different content different hash"
    PASS=$((PASS + 1))
else
    echo "  ✗ different content should have different hash"
    FAIL=$((FAIL + 1))
fi

# Test 3: Missing file returns "missing"
echo "Test 3: _file_hash missing file"
h4=$(_file_hash "$TMPDIR_ROOT/nonexistent.md")
assert_eq "missing file returns 'missing'" "missing" "$h4"

echo ""
echo "== Oscillation tracking variables in run_epic =="

# Test 4: Verify run_epic declares tracking variables
echo "Test 4: oscillation variables declared in run_epic"
grep -q 'prev_tasks_hash=""' "$SRC_DIR/autopilot.sh" && {
    echo "  ✓ prev_tasks_hash declared"; PASS=$((PASS + 1))
} || { echo "  ✗ prev_tasks_hash not declared"; FAIL=$((FAIL + 1)); }

grep -q 'same_hash_count=0' "$SRC_DIR/autopilot.sh" && {
    echo "  ✓ same_hash_count declared"; PASS=$((PASS + 1))
} || { echo "  ✗ same_hash_count not declared"; FAIL=$((FAIL + 1)); }

grep -q 'oscillation_stalled=false' "$SRC_DIR/autopilot.sh" && {
    echo "  ✓ oscillation_stalled declared"; PASS=$((PASS + 1))
} || { echo "  ✗ oscillation_stalled not declared"; FAIL=$((FAIL + 1)); }

echo ""
echo "== Stall detection threshold =="

# Test 5: Stall threshold is 3
echo "Test 5: stall threshold is 3 iterations"
grep -q 'same_hash_count -ge 3' "$SRC_DIR/autopilot.sh" && {
    echo "  ✓ threshold set to 3"; PASS=$((PASS + 1))
} || { echo "  ✗ threshold not set to 3"; FAIL=$((FAIL + 1)); }

# Test 6: oscillation_stalled wired into deferral logic
echo "Test 6: oscillation_stalled wired into retry exhaustion"
grep -q 'oscillation_stalled.*true.*||.*retries -ge' "$SRC_DIR/autopilot.sh" && {
    echo "  ✓ oscillation_stalled in deferral condition"; PASS=$((PASS + 1))
} || { echo "  ✗ oscillation_stalled not in deferral condition"; FAIL=$((FAIL + 1)); }

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
