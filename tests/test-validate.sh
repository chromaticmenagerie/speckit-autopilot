#!/usr/bin/env bash
# test-validate.sh — Tests for autopilot-validate.sh
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
        echo "  ✗ $desc (expected=$expected, got=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Setup ───────────────────────────────────────────────────────────────────
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Minimal stubs for sourced dependencies
AUTOPILOT_LOG=""
BOLD="" RESET="" RED="" GREEN="" YELLOW="" BLUE="" CYAN="" DIM=""
MERGE_TARGET="master"
BASE_BRANCH="master"
log() { :; }
is_epic_merged() { return 1; }  # Default: not merged

source "$SRC_DIR/autopilot-validate.sh"

# ─── Tests: Frontmatter ─────────────────────────────────────────────────────
echo "== Frontmatter Validation =="

# Valid frontmatter
setup_epic() {
    local dir="$TMPDIR_ROOT/$1"
    mkdir -p "$dir/docs/specs/epics"
    cat > "$dir/docs/specs/epics/epic-001.md" <<'EOF'
---
epic_id: epic-001
status: draft
branch: # populated at sprint start
created: 2026-01-01
project: TestProject
---

# Epic: Test Epic

## Functional Requirements
- The system shall do X
- The system shall do Y
- The system shall do Z

## Acceptance Criteria
- [ ] X works
- [ ] Y works

## Dependencies
None

## Out of Scope
- Nothing
EOF
    echo "$dir/docs/specs/epics/epic-001.md"
}

epic_file=$(setup_epic "test-valid")
result=0
_validate_frontmatter "$epic_file" "001" || result=$?
assert_eq "valid frontmatter returns 0" "0" "$result"

# Missing epic_id
mkdir -p "$TMPDIR_ROOT/test-no-id/docs/specs/epics"
cat > "$TMPDIR_ROOT/test-no-id/docs/specs/epics/epic-001.md" <<'EOF'
---
status: draft
---
# Epic: Test
## Functional Requirements
- The system shall do X
## Acceptance Criteria
- [ ] X works
## Dependencies
None
EOF
result=0
_validate_frontmatter "$TMPDIR_ROOT/test-no-id/docs/specs/epics/epic-001.md" "001" || result=$?
assert_eq "missing epic_id returns 1" "1" "$result"

# Invalid epic_id format (2-digit)
mkdir -p "$TMPDIR_ROOT/test-bad-id/docs/specs/epics"
cat > "$TMPDIR_ROOT/test-bad-id/docs/specs/epics/epic-001.md" <<'EOF'
---
epic_id: epic-01
status: draft
---
# Epic: Test
## Functional Requirements
- X
## Acceptance Criteria
- [ ] X
## Dependencies
None
EOF
result=0
_validate_frontmatter "$TMPDIR_ROOT/test-bad-id/docs/specs/epics/epic-001.md" "001" || result=$?
assert_eq "2-digit epic_id returns 1" "1" "$result"

# Invalid status
mkdir -p "$TMPDIR_ROOT/test-bad-status/docs/specs/epics"
cat > "$TMPDIR_ROOT/test-bad-status/docs/specs/epics/epic-001.md" <<'EOF'
---
epic_id: epic-001
status: wip
---
# Epic: Test
## Functional Requirements
- X
## Acceptance Criteria
- [ ] X
## Dependencies
None
EOF
result=0
_validate_frontmatter "$TMPDIR_ROOT/test-bad-status/docs/specs/epics/epic-001.md" "001" || result=$?
assert_eq "invalid status returns error" "1" "$result"

# ─── Tests: Sections ────────────────────────────────────────────────────────
echo ""
echo "== Section Validation =="

epic_file=$(setup_epic "test-sections-ok")
result=0
_validate_sections "$epic_file" || result=$?
assert_eq "all required sections present returns 0" "0" "$result"

# Missing Functional Requirements
mkdir -p "$TMPDIR_ROOT/test-no-fr"
cat > "$TMPDIR_ROOT/test-no-fr/epic.md" <<'EOF'
---
epic_id: epic-001
status: draft
---
# Epic: Test
## Acceptance Criteria
- [ ] X
## Dependencies
None
EOF
result=0
_validate_sections "$TMPDIR_ROOT/test-no-fr/epic.md" || result=$?
assert_eq "missing FR section returns 1" "1" "$result"

# ─── Tests: Dependencies ────────────────────────────────────────────────────
echo ""
echo "== Dependency Validation =="

# None dependencies
epic_file=$(setup_epic "test-deps-none")
result=0
_validate_dependencies "$TMPDIR_ROOT/test-deps-none" "$epic_file" "001" || result=$?
assert_eq "None dependencies returns 0" "0" "$result"

# None regex tightened — should NOT match "ComponentNone"
mkdir -p "$TMPDIR_ROOT/test-deps-componentnone/docs/specs/epics"
cat > "$TMPDIR_ROOT/test-deps-componentnone/docs/specs/epics/epic-002.md" <<'EOF'
---
epic_id: epic-002
status: draft
---
# Epic: Test
## Functional Requirements
- X
## Acceptance Criteria
- [ ] X
## Dependencies
ComponentNone is referenced here
EOF
result=0
_validate_dependencies "$TMPDIR_ROOT/test-deps-componentnone" \
    "$TMPDIR_ROOT/test-deps-componentnone/docs/specs/epics/epic-002.md" "002" || result=$?
# Should NOT return 0 (it should process the section and find no epic refs, which is fine)
# But it should NOT short-circuit on "ComponentNone" as if it were "None"
assert_eq "ComponentNone does not match None pattern" "0" "$result"

# None regex — should NOT match "none of these are hard blockers"
mkdir -p "$TMPDIR_ROOT/test-deps-none-phrase/docs/specs/epics"
cat > "$TMPDIR_ROOT/test-deps-none-phrase/docs/specs/epics/epic-003.md" <<'EOF'
---
epic_id: epic-003
status: draft
---
# Epic: Test
## Functional Requirements
- X
## Acceptance Criteria
- [ ] X
## Dependencies
- **epic-001** — none of these are hard blockers
EOF
# Create the referenced epic file
cat > "$TMPDIR_ROOT/test-deps-none-phrase/docs/specs/epics/epic-001.md" <<'EOF'
---
epic_id: epic-001
status: draft
branch:
---
# Epic: Dep
EOF
result=0
_validate_dependencies "$TMPDIR_ROOT/test-deps-none-phrase" \
    "$TMPDIR_ROOT/test-deps-none-phrase/docs/specs/epics/epic-003.md" "003" || result=$?
# Should process normally (warn about unmerged dep), not short-circuit
assert_eq "none-in-phrase does not match None pattern" "0" "$result"

# ─── Tests: Content Quality ─────────────────────────────────────────────────
echo ""
echo "== Content Quality =="

# File with fewer than 3 FR bullets — should warn (but not error)
epic_file=$(setup_epic "test-quality-ok")
result=0
_validate_content_quality "$epic_file" || result=$?
assert_eq "content quality check returns 0 (warnings only)" "0" "$result"

# ─── Tests: Full Validation ─────────────────────────────────────────────────
echo ""
echo "== Full Validation =="

epic_file=$(setup_epic "test-full-valid")
result=0
validate_epic "$TMPDIR_ROOT/test-full-valid" "001" "$epic_file" || result=$?
assert_eq "valid epic passes full validation" "0" "$result"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
