#!/usr/bin/env bash
# test-review-tiers.sh — Unit tests for tier dispatch, codex/self-review classifiers,
# config parsing, and update_managed_section.
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

# ─── Setup ──────────────────────────────────────────────────────────────────

# Stub log
log() { :; }

# Source helpers
source "$SRC_DIR/autopilot-review-helpers.sh"
source "$SRC_DIR/common.sh"

# ─── Tests: Helper dispatch (_review_is_clean) ────────────────────────────

echo "Test: _review_is_clean dispatch"

# cli tier dispatches to _cr_cli_is_clean
rc=0; _review_is_clean "cli" "" || rc=$?
assert_eq "0" "$rc" "cli: empty = clean (via _cr_cli_is_clean)"

rc=0; _review_is_clean "cli" "$(printf 'Starting CodeRabbit review for PR #42...\nAnalyzing changes across 3 files...\nReview completed: 5 findings')" || rc=$?
assert_eq "1" "$rc" "cli: findings = not clean"

# codex tier dispatches to _codex_is_clean
rc=0; _review_is_clean "codex" '{"overall_correctness":true,"findings":[]}' || rc=$?
assert_eq "0" "$rc" "codex: correct JSON = clean"

rc=0; _review_is_clean "codex" "" || rc=$?
assert_eq "1" "$rc" "codex: empty = not clean"

# self tier dispatches to _self_review_is_clean
rc=0; _review_is_clean "self" "No issues found." || rc=$?
assert_eq "0" "$rc" "self: no issues = clean"

rc=0; _review_is_clean "self" "CRITICAL: buffer overflow" || rc=$?
assert_eq "1" "$rc" "self: CRITICAL = not clean"

# unknown tier = not clean
rc=0; _review_is_clean "bogus" "anything" || rc=$?
assert_eq "1" "$rc" "unknown tier = not clean"

# ─── Tests: Helper dispatch (_count_review_issues) ───────────────────────

echo "Test: _count_review_issues dispatch"

result=$(_count_review_issues "cli" "$(printf 'Review completed: 7 findings')")
assert_eq "7" "$result" "cli dispatch: 7 findings"

result=$(_count_review_issues "codex" '{"findings":[{"priority":0},{"priority":1}]}')
assert_eq "2" "$result" "codex dispatch: 2 findings"

result=$(_count_review_issues "self" "$(printf 'CRITICAL: x\nHIGH: y\nMEDIUM: z')")
assert_eq "3" "$result" "self dispatch: 3 issues"

result=$(_count_review_issues "bogus" "whatever")
assert_eq "0" "$result" "unknown tier = 0"

# ─── Tests: Helper dispatch (_classify_review_error) ─────────────────────

echo "Test: _classify_review_error dispatch"

result=$(_classify_review_error "cli" "429 Too Many Requests")
assert_eq "rate_limit" "$result" "cli dispatch: rate_limit"

result=$(_classify_review_error "codex" "timeout exceeded")
assert_eq "timeout" "$result" "codex dispatch: timeout"

result=$(_classify_review_error "self" "anything")
assert_eq "claude_error" "$result" "self dispatch: always claude_error"

result=$(_classify_review_error "bogus" "anything")
assert_eq "unknown" "$result" "unknown tier = unknown"

# ─── Tests: _codex_is_clean ──────────────────────────────────────────────

echo "Test: _codex_is_clean"

# JSON: overall_correctness=true + no P0/P1 → clean
rc=0; _codex_is_clean '{"overall_correctness":true,"findings":[]}' || rc=$?
assert_eq "0" "$rc" "overall_correctness=true, empty findings = clean"

rc=0; _codex_is_clean '{"overall_correctness":true,"findings":[{"priority":3,"description":"style nit"}]}' || rc=$?
assert_eq "0" "$rc" "overall_correctness=true, only P3 = clean"

# JSON: overall_correctness=false → not clean
rc=0; _codex_is_clean '{"overall_correctness":false,"findings":[{"priority":0}]}' || rc=$?
assert_eq "1" "$rc" "overall_correctness=false = not clean"

# JSON: overall_correctness=true + P0 findings → not clean (conservative)
rc=0; _codex_is_clean '{"overall_correctness":true,"findings":[{"priority":0,"description":"critical bug"}]}' || rc=$?
assert_eq "1" "$rc" "overall_correctness=true + P0 = not clean (conservative)"

rc=0; _codex_is_clean '{"overall_correctness":true,"findings":[{"priority":1,"description":"high sev"}]}' || rc=$?
assert_eq "1" "$rc" "overall_correctness=true + P1 = not clean (conservative)"

# Text: "no issues" → clean
rc=0; _codex_is_clean "The code has no issues and appears correct." || rc=$?
assert_eq "0" "$rc" "text: 'no issues' = clean"

# Text: P0-P2 markers → not clean
rc=0; _codex_is_clean "[P0] Critical SQL injection in handler.go" || rc=$?
assert_eq "1" "$rc" "text: [P0] marker = not clean"

rc=0; _codex_is_clean "[P1] Missing auth check [P2] Unclosed connection" || rc=$?
assert_eq "1" "$rc" "text: [P1]+[P2] markers = not clean"

# Empty input → not clean
rc=0; _codex_is_clean "" || rc=$?
assert_eq "1" "$rc" "empty input = not clean"

# JSON with no overall_correctness but empty findings
rc=0; _codex_is_clean '{"findings":[]}' || rc=$?
assert_eq "0" "$rc" "no overall_correctness, empty findings = clean"

# JSON with no overall_correctness but non-empty findings
rc=0; _codex_is_clean '{"findings":[{"priority":1}]}' || rc=$?
assert_eq "1" "$rc" "no overall_correctness, non-empty findings = not clean"

# ─── Tests: _count_codex_issues ──────────────────────────────────────────

echo "Test: _count_codex_issues"

# JSON findings with priority
result=$(_count_codex_issues '{"findings":[{"priority":0},{"priority":1},{"priority":2},{"priority":3}]}')
assert_eq "3" "$result" "JSON: 3 findings P0-P2 (P3 excluded)"

# JSON with null priority (should default to 99, excluded)
result=$(_count_codex_issues '{"findings":[{"priority":null},{"priority":1}]}')
assert_eq "1" "$result" "JSON: null priority defaults to 99 (excluded)"

# Non-JSON input → 0
result=$(_count_codex_issues "plain text with no markers")
assert_eq "0" "$result" "non-JSON, no markers = 0"

# Non-JSON with P0-P2 markers (text fallback)
result=$(_count_codex_issues "$(printf '[P0] bug one\n[P1] bug two')")
assert_eq "2" "$result" "text: 2 P0-P2 markers"

# Empty input
result=$(_count_codex_issues "")
assert_eq "0" "$result" "empty input = 0"

# ─── Tests: _classify_codex_error ────────────────────────────────────────

echo "Test: _classify_codex_error"

result=$(_classify_codex_error "Rate limit exceeded (429)")
assert_eq "rate_limit" "$result" "rate limit"

result=$(_classify_codex_error "HTTP 401 Unauthorized")
assert_eq "auth_error" "$result" "auth error (401)"

result=$(_classify_codex_error "HTTP 403 Forbidden")
assert_eq "auth_error" "$result" "auth error (403)"

result=$(_classify_codex_error "Request timed out after 300s")
assert_eq "timeout" "$result" "timeout"

result=$(_classify_codex_error "some random codex error")
assert_eq "service_error" "$result" "unknown → service_error"

# ─── Tests: _self_review_is_clean ────────────────────────────────────────

echo "Test: _self_review_is_clean"

# "No issues found." → clean
rc=0; _self_review_is_clean "No issues found." || rc=$?
assert_eq "0" "$rc" "exact 'No issues found.' = clean"

rc=0; _self_review_is_clean "After thorough review: no findings detected." || rc=$?
assert_eq "0" "$rc" "'no findings' text = clean"

# CRITICAL findings → not clean
rc=0; _self_review_is_clean "CRITICAL: SQL injection in handler.go line 42" || rc=$?
assert_eq "1" "$rc" "CRITICAL finding = not clean"

# HIGH findings → not clean
rc=0; _self_review_is_clean "HIGH: missing authentication check" || rc=$?
assert_eq "1" "$rc" "HIGH finding = not clean"

# Only LOW findings → clean (no CRITICAL/HIGH)
rc=0; _self_review_is_clean "LOW: consider renaming variable for clarity" || rc=$?
assert_eq "0" "$rc" "only LOW findings = clean"

# Empty → not clean
rc=0; _self_review_is_clean "" || rc=$?
assert_eq "1" "$rc" "empty = not clean"

# LGTM → clean
rc=0; _self_review_is_clean "LGTM - code looks good" || rc=$?
assert_eq "0" "$rc" "LGTM = clean"

# ─── Tests: _count_self_issues ───────────────────────────────────────────

echo "Test: _count_self_issues"

result=$(_count_self_issues "$(printf 'CRITICAL: bug1\nHIGH: bug2\nMEDIUM: nit1')")
assert_eq "3" "$result" "3 issues: CRITICAL+HIGH+MEDIUM"

result=$(_count_self_issues "$(printf 'CRITICAL: one\nCRITICAL: two')")
assert_eq "2" "$result" "2 CRITICAL issues"

# Zero matches → single "0" (not "0\n0")
result=$(_count_self_issues "Everything looks great, no problems here")
assert_eq "0" "$result" "zero matches = '0'"

# Verify single line output (no double "0")
line_count=$(echo "$result" | wc -l | xargs)
assert_eq "1" "$line_count" "zero matches = single line output"

# ─── Tests: _check_stall (dispatch context) ──────────────────────────────

echo "Test: _check_stall (via dispatch)"

# Stall detection works same regardless of tier (it's tier-independent)
rc=0; _check_stall "5 3 3" 2 || rc=$?
assert_eq "0" "$rc" "stalled: last 2 identical (tier-independent)"

rc=0; _check_stall "5 3 2" 2 || rc=$?
assert_eq "1" "$rc" "not stalled: counts differ"

# ─── Tests: Config parsing (REVIEW_TIER_ORDER) ──────────────────────────

echo "Test: REVIEW_TIER_ORDER IFS splitting"

# Simulate IFS splitting as done in _tiered_review
REVIEW_TIER_ORDER="cli,codex,self"
IFS=',' read -ra tier_order <<< "$REVIEW_TIER_ORDER"
assert_eq "3" "${#tier_order[@]}" "3 tiers parsed"
assert_eq "cli" "${tier_order[0]}" "first tier = cli"
assert_eq "codex" "${tier_order[1]}" "second tier = codex"
assert_eq "self" "${tier_order[2]}" "third tier = self"

# Single tier
REVIEW_TIER_ORDER="self"
IFS=',' read -ra tier_order <<< "$REVIEW_TIER_ORDER"
assert_eq "1" "${#tier_order[@]}" "single tier parsed"
assert_eq "self" "${tier_order[0]}" "single tier = self"

# Two tiers (no CLI)
REVIEW_TIER_ORDER="codex,self"
IFS=',' read -ra tier_order <<< "$REVIEW_TIER_ORDER"
assert_eq "2" "${#tier_order[@]}" "2 tiers parsed"
assert_eq "codex" "${tier_order[0]}" "first = codex"
assert_eq "self" "${tier_order[1]}" "second = self"

# ─── Tests: update_managed_section ───────────────────────────────────────

echo "Test: update_managed_section"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Case 1: Creates new file with markers
NEW_FILE="$TMPDIR_TEST/new-agents.md"
update_managed_section "$NEW_FILE" "TEST-TOOL" "Hello from test"
assert_eq "0" "$?" "creates new file successfully"
content=$(cat "$NEW_FILE")
expected="<!-- BEGIN TEST-TOOL MANAGED BLOCK -->
Hello from test
<!-- END TEST-TOOL MANAGED BLOCK -->"
assert_eq "$expected" "$content" "new file has markers + content"

# Case 2: Updates existing block between markers
update_managed_section "$NEW_FILE" "TEST-TOOL" "Updated content"
content=$(cat "$NEW_FILE")
expected="<!-- BEGIN TEST-TOOL MANAGED BLOCK -->
Updated content
<!-- END TEST-TOOL MANAGED BLOCK -->"
assert_eq "$expected" "$content" "existing block updated"

# Case 3: Appends block when markers absent
EXISTING_FILE="$TMPDIR_TEST/existing.md"
printf 'Some existing content\nLine two\n' > "$EXISTING_FILE"
update_managed_section "$EXISTING_FILE" "NEW-BLOCK" "Appended section"
# Check existing content preserved
head_line=$(head -1 "$EXISTING_FILE")
assert_eq "Some existing content" "$head_line" "existing content preserved"
# Check markers appended
rc=0; grep -qF "<!-- BEGIN NEW-BLOCK MANAGED BLOCK -->" "$EXISTING_FILE" || rc=$?
assert_eq "0" "$rc" "begin marker appended"
rc=0; grep -qF "Appended section" "$EXISTING_FILE" || rc=$?
assert_eq "0" "$rc" "content appended"
rc=0; grep -qF "<!-- END NEW-BLOCK MANAGED BLOCK -->" "$EXISTING_FILE" || rc=$?
assert_eq "0" "$rc" "end marker appended"

# Case 4: Preserves content outside markers
MULTI_FILE="$TMPDIR_TEST/multi.md"
cat > "$MULTI_FILE" <<'EOF'
# Header
Some intro text

<!-- BEGIN TOOL-A MANAGED BLOCK -->
Old tool A content
<!-- END TOOL-A MANAGED BLOCK -->

Middle content stays

<!-- BEGIN TOOL-B MANAGED BLOCK -->
Tool B content
<!-- END TOOL-B MANAGED BLOCK -->

Footer text
EOF
update_managed_section "$MULTI_FILE" "TOOL-A" "New tool A content"
# Verify TOOL-A updated
rc=0; grep -qF "New tool A content" "$MULTI_FILE" || rc=$?
assert_eq "0" "$rc" "TOOL-A content updated"
# Verify old TOOL-A removed
rc=0; grep -qF "Old tool A content" "$MULTI_FILE" && rc=1 || rc=0
assert_eq "0" "$rc" "old TOOL-A content removed"
# Verify TOOL-B preserved
rc=0; grep -qF "Tool B content" "$MULTI_FILE" || rc=$?
assert_eq "0" "$rc" "TOOL-B content preserved"
# Verify header/footer preserved
rc=0; grep -qF "# Header" "$MULTI_FILE" || rc=$?
assert_eq "0" "$rc" "header preserved"
rc=0; grep -qF "Footer text" "$MULTI_FILE" || rc=$?
assert_eq "0" "$rc" "footer preserved"
rc=0; grep -qF "Middle content stays" "$MULTI_FILE" || rc=$?
assert_eq "0" "$rc" "middle content preserved"

# Case 5: Multiline content with backslash paths (regression: awk newline bug)
MULTI_CONTENT_FILE="$TMPDIR_TEST/multiline.md"
cat > "$MULTI_CONTENT_FILE" <<'EOF'
# Document Header

<!-- BEGIN ML-TOOL MANAGED BLOCK -->
old single line
<!-- END ML-TOOL MANAGED BLOCK -->

Trailing paragraph
EOF
MULTILINE_BODY="Line one of new content
C:\Users\admin\project\build
Line three ending"
update_managed_section "$MULTI_CONTENT_FILE" "ML-TOOL" "$MULTILINE_BODY"
# Verify all three lines present
rc=0; grep -qF "Line one of new content" "$MULTI_CONTENT_FILE" || rc=$?
assert_eq "0" "$rc" "multiline: line 1 present"
rc=0; grep -qF 'C:\Users\admin\project\build' "$MULTI_CONTENT_FILE" || rc=$?
assert_eq "0" "$rc" "multiline: backslash path line present"
rc=0; grep -qF "Line three ending" "$MULTI_CONTENT_FILE" || rc=$?
assert_eq "0" "$rc" "multiline: line 3 present"
# Verify old content removed
rc=0; grep -qF "old single line" "$MULTI_CONTENT_FILE" && rc=1 || rc=0
assert_eq "0" "$rc" "multiline: old content removed"
# Verify markers preserved
rc=0; grep -qF "<!-- BEGIN ML-TOOL MANAGED BLOCK -->" "$MULTI_CONTENT_FILE" || rc=$?
assert_eq "0" "$rc" "multiline: begin marker preserved"
rc=0; grep -qF "<!-- END ML-TOOL MANAGED BLOCK -->" "$MULTI_CONTENT_FILE" || rc=$?
assert_eq "0" "$rc" "multiline: end marker preserved"
# Verify surrounding content preserved
rc=0; grep -qF "# Document Header" "$MULTI_CONTENT_FILE" || rc=$?
assert_eq "0" "$rc" "multiline: header preserved"
rc=0; grep -qF "Trailing paragraph" "$MULTI_CONTENT_FILE" || rc=$?
assert_eq "0" "$rc" "multiline: trailing content preserved"

# ─── Tests: Tier-skip (HAS_CODERABBIT / HAS_CODEX) ──────────────────────────

echo "Test: Tier-skip guards"

# Stubs needed for tier functions (autopilot-review.sh not sourced in this file)
_emit_event() { :; }
invoke_claude() { return 0; }
prompt_review_fix() { echo "fix prompt stub"; }
prompt_self_review() { echo "self review prompt stub"; }
prompt_self_review_chunk() { echo "chunk prompt stub"; }
ensure_coderabbit_config() { :; }

# Point SCRIPT_DIR to src/ so autopilot-review.sh can source its helpers
SCRIPT_DIR="$SRC_DIR"
source "$SRC_DIR/autopilot-review.sh"

# HAS_CODERABBIT=false → _tier_coderabbit_cli returns 2 (skip)
HAS_CODERABBIT=false
rc=0; _tier_coderabbit_cli "/tmp" "main" || rc=$?
assert_eq "2" "$rc" "HAS_CODERABBIT=false → tier returns 2"

# HAS_CODEX=false → _tier_codex returns 2 (skip)
HAS_CODEX=false
rc=0; _tier_codex "/tmp" "main" || rc=$?
assert_eq "2" "$rc" "HAS_CODEX=false → tier returns 2"

# ─── Tests: Backward-compat config aliases ───────────────────────────────────

echo "Test: Backward-compat config aliases"

# Replicate alias logic from autopilot-lib.sh (lines 560-577) inline
# to avoid sourcing autopilot-lib.sh which has heavy side effects.

# Test 1: SKIP_CODERABBIT=true → SKIP_REVIEW=true
result=$(SKIP_CODERABBIT=true bash -c 'SKIP_REVIEW="${SKIP_REVIEW:-${SKIP_CODERABBIT:-false}}"; echo "$SKIP_REVIEW"')
assert_eq "true" "$result" "SKIP_CODERABBIT=true → SKIP_REVIEW=true"

# Test 2: FORCE_ADVANCE_ON_REVIEW_FAIL=true → both STALL and ERROR = true
result=$(
    FORCE_ADVANCE_ON_REVIEW_STALL=""
    FORCE_ADVANCE_ON_REVIEW_ERROR=""
    FORCE_ADVANCE_ON_REVIEW_FAIL=true
    if [[ -z "$FORCE_ADVANCE_ON_REVIEW_STALL" ]]; then
        FORCE_ADVANCE_ON_REVIEW_STALL="${FORCE_ADVANCE_ON_REVIEW_FAIL:-false}"
    fi
    if [[ -z "$FORCE_ADVANCE_ON_REVIEW_ERROR" ]]; then
        FORCE_ADVANCE_ON_REVIEW_ERROR="${FORCE_ADVANCE_ON_REVIEW_FAIL:-false}"
    fi
    echo "${FORCE_ADVANCE_ON_REVIEW_STALL},${FORCE_ADVANCE_ON_REVIEW_ERROR}"
)
assert_eq "true,true" "$result" "FORCE_ADVANCE_ON_REVIEW_FAIL=true → STALL+ERROR=true"

# Test 3: HAS_CODERABBIT=true HAS_CODEX=false → tier order = cli,self
result=$(
    REVIEW_TIER_ORDER=""
    HAS_CODERABBIT=true
    HAS_CODEX=false
    if [[ -z "$REVIEW_TIER_ORDER" ]]; then
        tiers=""
        [[ "${HAS_CODERABBIT:-false}" == "true" ]] && tiers="cli"
        [[ "${HAS_CODEX:-false}" == "true" ]] && tiers="${tiers:+$tiers,}codex"
        tiers="${tiers:+$tiers,}self"
        REVIEW_TIER_ORDER="$tiers"
    fi
    echo "$REVIEW_TIER_ORDER"
)
assert_eq "cli,self" "$result" "HAS_CODERABBIT=true HAS_CODEX=false → cli,self"

# Test 4: HAS_CODERABBIT=false HAS_CODEX=true → tier order = codex,self
result=$(
    REVIEW_TIER_ORDER=""
    HAS_CODERABBIT=false
    HAS_CODEX=true
    if [[ -z "$REVIEW_TIER_ORDER" ]]; then
        tiers=""
        [[ "${HAS_CODERABBIT:-false}" == "true" ]] && tiers="cli"
        [[ "${HAS_CODEX:-false}" == "true" ]] && tiers="${tiers:+$tiers,}codex"
        tiers="${tiers:+$tiers,}self"
        REVIEW_TIER_ORDER="$tiers"
    fi
    echo "$REVIEW_TIER_ORDER"
)
assert_eq "codex,self" "$result" "HAS_CODERABBIT=false HAS_CODEX=true → codex,self"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
