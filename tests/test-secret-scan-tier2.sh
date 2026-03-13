#!/usr/bin/env bash
# test-secret-scan-tier2.sh — Verify Tier 2 findings → fix loop (return 0, tier=2)
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

# Create a mock gitleaks that outputs Tier 2 (generic) findings
MOCK_BIN="$TMPDIR_ROOT/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gitleaks" <<'MOCK'
#!/usr/bin/env bash
# Mock gitleaks: write Tier 2 finding to report, exit 2
report=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report-path) report="$2"; shift 2 ;;
        --report-path=*) report="${1#*=}"; shift ;;
        *) shift ;;
    esac
done
cat > "$report" <<'JSON'
[{"RuleID":"generic-api-key","File":"app.py","StartLine":10,"Secret":"REDACTED","Match":"API_KEY=abc123***","Fingerprint":"app.py:generic-api-key:10"}]
JSON
exit 2
MOCK
chmod +x "$MOCK_BIN/gitleaks"
export PATH="$MOCK_BIN:$PATH"

# Source verify functions
source "$SRC_DIR/autopilot-verify.sh"

echo "=== Tier 2 secret scan tests ==="

# Test 1: Tier 2 finding → return 0, LAST_SECRET_SCAN_TIER=2
echo "Test 1: Tier 2 (generic-api-key) → fix loop"
repo="$TMPDIR_ROOT/repo1"
mkdir -p "$repo"
(cd "$repo" && git init -q && git commit --allow-empty -m "init" -q)
PROJECT_SECRET_SCAN_CMD="gitleaks"
PROJECT_SECRET_SCAN_MODE="full"
MERGE_TARGET="main"
LAST_CI_OUTPUT=""
LAST_SECRET_SCAN_TIER=0
rc=0
verify_secrets "$repo" || rc=$?
assert_eq "0" "$rc" "returns 0 on Tier 2 finding"
assert_eq "2" "$LAST_SECRET_SCAN_TIER" "tier set to 2"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
