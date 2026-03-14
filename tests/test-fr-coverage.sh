#!/usr/bin/env bash
# test-fr-coverage.sh — Verify check_fr_coverage() detects FR-to-task gaps
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: '$haystack' does not contain '$needle'"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Source the library
AUTOPILOT_LOG=""
BASE_BRANCH="master"
source "$SRC_DIR/autopilot-lib.sh"

# Stub functions not needed for these tests
find_pen_file() { echo ""; }
is_epic_merged() { return 1; }

# ─── Test: all FRs covered → returns 0 ──────────────────────────────────────

echo "Test: all FRs covered returns 0"

spec_dir="$TMPDIR/all-covered"
mkdir -p "$spec_dir"

cat > "$spec_dir/spec.md" <<'EOF'
# Feature Spec
**FR-001** User login
**FR-002** User logout
**FR-003** Password reset
EOF

cat > "$spec_dir/tasks.md" <<'EOF'
## Phase 1
- [ ] Implement FR-001 login form
- [ ] Implement FR-002 logout button
- [ ] Implement FR-003 password reset flow
EOF

rc=0
stderr_out=$(check_fr_coverage "$spec_dir" 2>&1) || rc=$?
assert_eq "0" "$rc" "returns 0 when all FRs covered"
assert_contains "$stderr_out" "All FRs" "logs success message"

# ─── Test: missing FRs → returns 1 and logs them ────────────────────────────

echo "Test: missing FRs returns 1 and logs missing identifiers"

spec_dir="$TMPDIR/missing-frs"
mkdir -p "$spec_dir"

cat > "$spec_dir/spec.md" <<'EOF'
# Feature Spec
**FR-001** User login
**FR-002** User logout
**FR-003** Password reset
**FR-004** Two-factor auth
EOF

cat > "$spec_dir/tasks.md" <<'EOF'
## Phase 1
- [ ] Implement FR-001 login form
- [ ] Implement FR-003 password reset flow
EOF

rc=0
stderr_out=$(check_fr_coverage "$spec_dir" 2>&1) || rc=$?
assert_eq "1" "$rc" "returns 1 when FRs missing"
assert_contains "$stderr_out" "FR-002" "logs FR-002 as missing"
assert_contains "$stderr_out" "FR-004" "logs FR-004 as missing"

# ─── Test: no FRs in spec.md → returns 0 (skip) ─────────────────────────────

echo "Test: no FRs in spec.md returns 0 (skip check)"

spec_dir="$TMPDIR/no-frs"
mkdir -p "$spec_dir"

cat > "$spec_dir/spec.md" <<'EOF'
# Feature Spec
This spec has no formal FR identifiers.
EOF

cat > "$spec_dir/tasks.md" <<'EOF'
## Phase 1
- [ ] Do something
EOF

rc=0
check_fr_coverage "$spec_dir" 2>/dev/null || rc=$?
assert_eq "0" "$rc" "returns 0 when no FRs in spec"

# ─── Test: no spec.md → returns 0 (skip) ────────────────────────────────────

echo "Test: no spec.md returns 0 (skip check)"

spec_dir="$TMPDIR/no-spec"
mkdir -p "$spec_dir"

cat > "$spec_dir/tasks.md" <<'EOF'
## Phase 1
- [ ] Do something
EOF

rc=0
check_fr_coverage "$spec_dir" 2>/dev/null || rc=$?
assert_eq "0" "$rc" "returns 0 when spec.md missing"

# ─── Test: no tasks.md → returns 0 (skip) ───────────────────────────────────

echo "Test: no tasks.md returns 0 (skip check)"

spec_dir="$TMPDIR/no-tasks"
mkdir -p "$spec_dir"

cat > "$spec_dir/spec.md" <<'EOF'
# Feature Spec
**FR-001** Something
EOF

rc=0
check_fr_coverage "$spec_dir" 2>/dev/null || rc=$?
assert_eq "0" "$rc" "returns 0 when tasks.md missing"

# ─── Test: duplicate FRs in spec only counted once ──────────────────────────

echo "Test: duplicate FRs in spec counted once"

spec_dir="$TMPDIR/dup-frs"
mkdir -p "$spec_dir"

cat > "$spec_dir/spec.md" <<'EOF'
# Feature Spec
**FR-001** User login
**FR-001** User login (repeated)
**FR-002** User logout
EOF

cat > "$spec_dir/tasks.md" <<'EOF'
## Phase 1
- [ ] Implement FR-001 login form
- [ ] Implement FR-002 logout button
EOF

rc=0
check_fr_coverage "$spec_dir" 2>/dev/null || rc=$?
assert_eq "0" "$rc" "returns 0 with duplicate FRs all covered"

# ─── Test: PARTIAL vs NOT_FOUND classification in requirements findings ────

echo "Test: PARTIAL and NOT_FOUND are classified separately in findings"

findings_dir="$TMPDIR/findings-classify"
mkdir -p "$findings_dir"

cat > "$findings_dir/requirement-findings.md" <<'EOF'
# Requirement Verification Findings
FR-001: PASS
FR-002: PARTIAL
FR-003: NOT_FOUND
FR-004: PASS
FR-005: DEFERRED
EOF

findings_file="$findings_dir/requirement-findings.md"

has_not_found=false
has_partial=false
grep -qE ': NOT_FOUND' "$findings_file" && has_not_found=true
grep -qE ': PARTIAL' "$findings_file" && has_partial=true
assert_eq "true" "$has_not_found" "NOT_FOUND detected"
assert_eq "true" "$has_partial" "PARTIAL detected"

# Verify counts
pass_count=$(grep -c ': PASS' "$findings_file" 2>/dev/null || echo 0)
partial_count=$(grep -c ': PARTIAL' "$findings_file" 2>/dev/null || echo 0)
deferred_count=$(grep -c ': DEFERRED' "$findings_file" 2>/dev/null || echo 0)
not_found_count=$(grep -c ': NOT_FOUND' "$findings_file" 2>/dev/null || echo 0)
safe_count=$((pass_count + partial_count))
actionable=$((pass_count + partial_count + not_found_count))
pct=$((safe_count * 100 / actionable))

assert_eq "2" "$pass_count" "pass_count=2"
assert_eq "1" "$partial_count" "partial_count=1"
assert_eq "1" "$deferred_count" "deferred_count=1"
assert_eq "1" "$not_found_count" "not_found_count=1"
assert_eq "75" "$pct" "coverage pct=75 (3/4 actionable)"

# ─── Test: all DEFERRED (actionable=0) → no division by zero ─────────────

echo "Test: all DEFERRED → actionable=0, no division by zero"

cat > "$findings_dir/requirement-findings.md" <<'EOF'
FR-001: DEFERRED
FR-002: DEFERRED
FR-003: DEFERRED
EOF

pass_count=$(grep -c ': PASS' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
partial_count=$(grep -c ': PARTIAL' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
deferred_count=$(grep -c ': DEFERRED' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
not_found_count=$(grep -c ': NOT_FOUND' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
safe_count=$((pass_count + partial_count))
actionable=$((pass_count + partial_count + not_found_count))
assert_eq "0" "$actionable" "all-DEFERRED: actionable=0"
assert_eq "0" "$safe_count" "all-DEFERRED: safe_count=0"

# ─── Test: 0 PASS + 0 PARTIAL + 1 NOT_FOUND + 10 DEFERRED ──────────────

echo "Test: 0 PASS + 0 PARTIAL + 1 NOT_FOUND + 10 DEFERRED → pct=0"

cat > "$findings_dir/requirement-findings.md" <<'EOF'
FR-001: NOT_FOUND
FR-002: DEFERRED
FR-003: DEFERRED
FR-004: DEFERRED
FR-005: DEFERRED
FR-006: DEFERRED
FR-007: DEFERRED
FR-008: DEFERRED
FR-009: DEFERRED
FR-010: DEFERRED
FR-011: DEFERRED
EOF

pass_count=$(grep -c ': PASS' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
partial_count=$(grep -c ': PARTIAL' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
not_found_count=$(grep -c ': NOT_FOUND' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
safe_count=$((pass_count + partial_count))
actionable=$((pass_count + partial_count + not_found_count))
pct=$((safe_count * 100 / actionable))
assert_eq "1" "$actionable" "1-NOT_FOUND+10-DEFERRED: actionable=1"
assert_eq "0" "$pct" "1-NOT_FOUND+10-DEFERRED: pct=0"

# ─── Test: single FR (1 PASS) → actionable=1, pct=100% ─────────────────

echo "Test: single FR (1 PASS) → pct=100"

cat > "$findings_dir/requirement-findings.md" <<'EOF'
FR-001: PASS
EOF

pass_count=$(grep -c ': PASS' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
partial_count=$(grep -c ': PARTIAL' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
not_found_count=$(grep -c ': NOT_FOUND' "$findings_dir/requirement-findings.md" 2>/dev/null) || true
safe_count=$((pass_count + partial_count))
actionable=$((pass_count + partial_count + not_found_count))
pct=$((safe_count * 100 / actionable))
assert_eq "1" "$actionable" "single-PASS: actionable=1"
assert_eq "100" "$pct" "single-PASS: pct=100"

echo "Test: all-PASS findings have no NOT_FOUND or PARTIAL"

cat > "$findings_dir/requirement-findings.md" <<'EOF'
FR-001: PASS
FR-002: PASS
EOF

has_not_found=false
has_partial=false
grep -qE ': NOT_FOUND' "$findings_dir/requirement-findings.md" && has_not_found=true
grep -qE ': PARTIAL' "$findings_dir/requirement-findings.md" && has_partial=true
assert_eq "false" "$has_not_found" "no NOT_FOUND in all-PASS"
assert_eq "false" "$has_partial" "no PARTIAL in all-PASS"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
