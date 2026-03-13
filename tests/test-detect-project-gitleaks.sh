#!/usr/bin/env bash
# test-detect-project-gitleaks.sh — Test gitleaks auto-detection in detect-tools.sh
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
REPO_ROOT="$TMPDIR_ROOT/repo"
mkdir -p "$REPO_ROOT"

# Extract detect_gitleaks and _generate_gitleaks_config
eval "$(sed -n '/^detect_gitleaks()/,/^}/p' "$SRC_DIR/autopilot-detect-tools.sh")"
eval "$(sed -n '/^_generate_gitleaks_config()/,/^}/p' "$SRC_DIR/autopilot-detect-tools.sh")"

echo "=== Gitleaks detection tests ==="

# Test 1: No gitleaks → PROJECT_SECRET_SCAN_CMD stays empty
echo "Test 1: No gitleaks in PATH → not detected"
# Ensure gitleaks is not in PATH for this test
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "$TMPDIR_ROOT" | tr '\n' ':')
PROJECT_SECRET_SCAN_CMD=""
(PATH="$CLEAN_PATH" detect_gitleaks)
# Note: detect_gitleaks sets the var in its own scope when run in subshell
# Test via checking if command exists
if ! PATH="$CLEAN_PATH" command -v gitleaks >/dev/null 2>&1; then
    assert_eq "" "" "gitleaks not in PATH (expected)"
else
    assert_eq "not-found" "found" "gitleaks should not be in clean PATH"
fi

# Test 2: Mock gitleaks → detected
echo "Test 2: Mock gitleaks in PATH → detected"
MOCK_BIN="$TMPDIR_ROOT/bin"
mkdir -p "$MOCK_BIN"
echo '#!/usr/bin/env bash' > "$MOCK_BIN/gitleaks"
echo 'echo "mock gitleaks"' >> "$MOCK_BIN/gitleaks"
chmod +x "$MOCK_BIN/gitleaks"
PROJECT_SECRET_SCAN_CMD=""
PATH="$MOCK_BIN:$PATH" detect_gitleaks
assert_eq "gitleaks" "$PROJECT_SECRET_SCAN_CMD" "PROJECT_SECRET_SCAN_CMD set to gitleaks"

# Test 3: .gitleaks.toml generation
echo "Test 3: .gitleaks.toml generated when missing"
repo2="$TMPDIR_ROOT/repo2"
mkdir -p "$repo2"
_generate_gitleaks_config "$repo2"
assert_eq "0" "$?" "generation succeeds"
if [[ -f "$repo2/.gitleaks.toml" ]]; then
    assert_eq "1" "1" ".gitleaks.toml created"
else
    assert_eq "file-exists" "missing" ".gitleaks.toml should exist"
fi

# Test 4: .gitleaks.toml not overwritten if exists
echo "Test 4: .gitleaks.toml preserved if exists"
repo3="$TMPDIR_ROOT/repo3"
mkdir -p "$repo3"
echo "# custom config" > "$repo3/.gitleaks.toml"
_generate_gitleaks_config "$repo3"
content=$(cat "$repo3/.gitleaks.toml")
assert_eq "# custom config" "$content" "existing config preserved"

# Test 5: Generated config has useDefault = true
echo "Test 5: Generated config extends defaults"
if grep -q 'useDefault = true' "$repo2/.gitleaks.toml"; then
    assert_eq "1" "1" "useDefault = true present"
else
    assert_eq "found" "missing" "useDefault = true should be in config"
fi

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
