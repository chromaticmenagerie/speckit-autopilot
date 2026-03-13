#!/usr/bin/env bash
# test-secret-scan-tier1.sh — Verify Tier 1 detection → immediate HALT
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

# Create a mock gitleaks that outputs Tier 1 findings
MOCK_BIN="$TMPDIR_ROOT/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gitleaks" <<'MOCK'
#!/usr/bin/env bash
# Mock gitleaks: write Tier 1 finding to report, exit 2
report=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report-path) report="$2"; shift 2 ;;
        --report-path=*) report="${1#*=}"; shift ;;
        *) shift ;;
    esac
done
cat > "$report" <<'JSON'
[{"RuleID":"aws-access-token","File":"config.py","StartLine":5,"Secret":"REDACTED","Match":"AKIA***","Fingerprint":"config.py:aws-access-token:5"}]
JSON
exit 2
MOCK
chmod +x "$MOCK_BIN/gitleaks"
export PATH="$MOCK_BIN:$PATH"

# Source verify functions
source "$SRC_DIR/autopilot-verify.sh"

echo "=== Tier 1 secret scan tests ==="

# Test 1: Tier 1 finding → return 1, LAST_SECRET_SCAN_TIER=1
echo "Test 1: Tier 1 (aws-access-token) → HALT"
repo="$TMPDIR_ROOT/repo1"
mkdir -p "$repo"
(cd "$repo" && git init -q && git commit --allow-empty -m "init" -q)
PROJECT_SECRET_SCAN_CMD="gitleaks"
PROJECT_SECRET_SCAN_MODE="full"
MERGE_TARGET="main"
LAST_SECRET_SCAN_TIER=0
rc=0
verify_secrets "$repo" || rc=$?
assert_eq "1" "$rc" "returns 1 on Tier 1 finding"
assert_eq "1" "$LAST_SECRET_SCAN_TIER" "tier set to 1"

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
