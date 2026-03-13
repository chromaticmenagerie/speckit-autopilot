#!/usr/bin/env bash
# test-pre-merge-summary.sh — Tests for pre-merge gate history check (Item 22)
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

# ─── Tests ───────────────────────────────────────────────────────────────────
echo "== Pre-merge skip_summary grep logic =="

# Test 1: All four markers present
echo "Test 1: All four markers detected"
tasks_file="$TMPDIR_ROOT/tasks-all.md"
cat > "$tasks_file" <<'EOF'
## Phase 1
- [x] Task 1
<!-- SECURITY_FORCE_SKIPPED -->
<!-- REQUIREMENTS_FORCE_SKIPPED -->
<!-- REVIEW_FORCE_SKIPPED -->
<!-- VERIFY_CI_FORCE_SKIPPED -->
EOF

skip_summary="" skip_count=0
grep -q 'SECURITY_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Security: findings force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'REQUIREMENTS_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Requirements: gaps force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'REVIEW_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Review: issues force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'VERIFY_CI_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - CI: failures force-skipped\n"; skip_count=$((skip_count+1)); }
assert_eq "4 markers = 4 skips" "4" "$skip_count"

# Test 2: Only security marker
echo "Test 2: Only security marker"
tasks_file="$TMPDIR_ROOT/tasks-sec.md"
cat > "$tasks_file" <<'EOF'
## Phase 1
- [x] Task 1
<!-- SECURITY_FORCE_SKIPPED -->
EOF

skip_summary="" skip_count=0
grep -q 'SECURITY_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Security: findings force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'REQUIREMENTS_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Requirements: gaps force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'REVIEW_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Review: issues force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'VERIFY_CI_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - CI: failures force-skipped\n"; skip_count=$((skip_count+1)); }
assert_eq "1 marker = 1 skip" "1" "$skip_count"

# Test 3: No markers — skip_count stays 0
echo "Test 3: No markers = 0 skips"
tasks_file="$TMPDIR_ROOT/tasks-clean.md"
cat > "$tasks_file" <<'EOF'
## Phase 1
- [x] Task 1
- [x] Task 2
<!-- SECURITY_REVIEWED -->
<!-- VERIFY_CI_COMPLETE -->
EOF

skip_summary="" skip_count=0
grep -q 'SECURITY_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Security: findings force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'REQUIREMENTS_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Requirements: gaps force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'REVIEW_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Review: issues force-skipped\n"; skip_count=$((skip_count+1)); }
grep -q 'VERIFY_CI_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - CI: failures force-skipped\n"; skip_count=$((skip_count+1)); }
assert_eq "no markers = 0 skips" "0" "$skip_count"

# Test 4: Missing file — no crash
echo "Test 4: Missing file = 0 skips (no crash)"
skip_summary="" skip_count=0
grep -q 'SECURITY_FORCE_SKIPPED' "$TMPDIR_ROOT/nonexistent.md" 2>/dev/null && { skip_count=$((skip_count+1)); }
grep -q 'REQUIREMENTS_FORCE_SKIPPED' "$TMPDIR_ROOT/nonexistent.md" 2>/dev/null && { skip_count=$((skip_count+1)); }
grep -q 'REVIEW_FORCE_SKIPPED' "$TMPDIR_ROOT/nonexistent.md" 2>/dev/null && { skip_count=$((skip_count+1)); }
grep -q 'VERIFY_CI_FORCE_SKIPPED' "$TMPDIR_ROOT/nonexistent.md" 2>/dev/null && { skip_count=$((skip_count+1)); }
assert_eq "missing file = 0 skips" "0" "$skip_count"

# Test 5: Verify do_merge and do_remote_merge both have the check
echo "Test 5: do_merge has pre-merge summary"
grep -q 'PRE-MERGE RISK SUMMARY' "$SRC_DIR/autopilot.sh" && {
    echo "  ✓ do_merge has PRE-MERGE RISK SUMMARY"; PASS=$((PASS + 1))
} || { echo "  ✗ do_merge missing PRE-MERGE RISK SUMMARY"; FAIL=$((FAIL + 1)); }

echo "Test 6: do_remote_merge has pre-merge summary"
grep -q 'PRE-MERGE RISK SUMMARY' "$SRC_DIR/autopilot-merge.sh" && {
    echo "  ✓ do_remote_merge has PRE-MERGE RISK SUMMARY"; PASS=$((PASS + 1))
} || { echo "  ✗ do_remote_merge missing PRE-MERGE RISK SUMMARY"; FAIL=$((FAIL + 1)); }

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
