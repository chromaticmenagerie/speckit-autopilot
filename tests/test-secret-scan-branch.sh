#!/usr/bin/env bash
# test-secret-scan-branch.sh — Verify branch-mode scans only changed files
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

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

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Stubs
log() { :; }
run_with_timeout() { shift; "$@"; }
_exec_in_new_pgrp() { "$@"; }

# Mock gitleaks: reports findings in BOTH old.py and new.py
MOCK_BIN="$TMPDIR_ROOT/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gitleaks" <<'MOCK'
#!/usr/bin/env bash
report=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report-path) report="$2"; shift 2 ;;
        --report-path=*) report="${1#*=}"; shift ;;
        *) shift ;;
    esac
done
# Findings in two files: old.py (pre-existing) and new.py (branch-changed)
cat > "$report" <<'JSON'
[
  {"RuleID":"generic-api-key","File":"old.py","StartLine":1,"Secret":"REDACTED","Match":"KEY=old***","Fingerprint":"old.py:generic-api-key:1"},
  {"RuleID":"generic-api-key","File":"new.py","StartLine":1,"Secret":"REDACTED","Match":"KEY=new***","Fingerprint":"new.py:generic-api-key:1"}
]
JSON
exit 2
MOCK
chmod +x "$MOCK_BIN/gitleaks"
export PATH="$MOCK_BIN:$PATH"

source "$SRC_DIR/autopilot-verify.sh"

echo "=== Branch-mode secret scan tests ==="

# Set up a git repo with main and a feature branch
repo="$TMPDIR_ROOT/repo1"
mkdir -p "$repo"
(cd "$repo" && git init -q && git checkout -q -b main)
echo "KEY=oldvalue" > "$repo/old.py"
(cd "$repo" && git add old.py && git commit -q -m "add old.py")
(cd "$repo" && git checkout -q -b feature)
echo "KEY=newvalue" > "$repo/new.py"
(cd "$repo" && git add new.py && git commit -q -m "add new.py")

# Test 1: branch mode → only new.py findings (old.py filtered out)
echo "Test 1: Branch mode filters to changed files only"
PROJECT_SECRET_SCAN_CMD="gitleaks"
PROJECT_SECRET_SCAN_MODE="branch"
MERGE_TARGET="main"
LAST_CI_OUTPUT=""
LAST_SECRET_SCAN_TIER=0
rc=0
verify_secrets "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 (Tier 2, 1 finding after filter)"
assert_eq "2" "$LAST_SECRET_SCAN_TIER" "tier=2 (generic in new.py)"

# Test 2: full mode → both files included → 2 findings
echo "Test 2: Full mode includes all files"
PROJECT_SECRET_SCAN_MODE="full"
LAST_CI_OUTPUT=""
LAST_SECRET_SCAN_TIER=0
rc=0
verify_secrets "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 (Tier 2)"
assert_eq "2" "$LAST_SECRET_SCAN_TIER" "tier=2 (both files)"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
