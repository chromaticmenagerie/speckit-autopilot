#!/usr/bin/env bash
# test-config-precedence.sh — Verify CLI flags override project.env values
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

log() { :; }
declare -A PHASE_MAX_RETRIES=()
TARGET_EPIC=""
TARGET_EPICS=()
AUTO_CONTINUE=true
DRY_RUN=false
SILENT=false
NO_GITHUB=false
GITHUB_RESYNC=false
STRICT_DEPS=false
ALLOW_DEFERRED=false
SKIP_CODERABBIT=false
SKIP_REVIEW=false
SECURITY_FORCE_SKIP_ALLOWED=false
REQUIREMENTS_FORCE_SKIP_ALLOWED=false
MAX_ITERATIONS=""

eval "$(sed -n '/^parse_args()/,/^}/p' "$SRC_DIR/autopilot.sh")"

# ─── Tests ──────────────────────────────────────────────────────────────────

echo "=== Config Precedence Tests ==="

# Test 1: CLI --max-iterations overrides a pre-set (project.env) value
echo "Test 1: CLI --max-iterations overrides project.env MAX_ITERATIONS"
MAX_ITERATIONS=40   # simulate project.env setting
parse_args --max-iterations 10
assert_eq "10" "$MAX_ITERATIONS" "CLI --max-iterations 10 overrides env 40"

# Test 2: project.env value persists when no CLI flag given
echo "Test 2: project.env value kept when no CLI flag"
MAX_ITERATIONS=40   # simulate project.env setting
parse_args
assert_eq "40" "$MAX_ITERATIONS" "project.env MAX_ITERATIONS=40 retained"

# Test 3: main() ordering — verify load_project_config comes before parse_args
echo "Test 3: main() calls load_project_config before parse_args"
main_body="$(sed -n '/^main()/,/^}/p' "$SRC_DIR/autopilot.sh")"
line_load=$(echo "$main_body" | grep -n 'load_project_config' | head -1 | cut -d: -f1)
line_parse=$(echo "$main_body" | grep -n 'parse_args' | head -1 | cut -d: -f1)
if [[ -n "$line_load" && -n "$line_parse" && "$line_load" -lt "$line_parse" ]]; then
    assert_eq "1" "1" "load_project_config (line $line_load) before parse_args (line $line_parse)"
else
    assert_eq "load<parse" "load=$line_load parse=$line_parse" "load_project_config must precede parse_args"
fi

# Test 4: jq preflight check is still present in main()
echo "Test 4: jq preflight check present in main()"
jq_check=$(echo "$main_body" | grep -c 'command -v jq' || true)
assert_eq "1" "$jq_check" "jq preflight check in main()"

# ─── Results ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
