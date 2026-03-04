#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/src"

# Test framework (reuse from other tests)
TESTS=0 PASSED=0 FAILED=0
assert() {
    local label="$1" condition="$2"
    TESTS=$((TESTS + 1))
    if eval "$condition"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        echo "FAIL: $label"
    fi
}

# Helper to detect frontend in a given directory
detect_frontend_in() {
    local dir="$1"
    if find "$dir" -maxdepth 4 \( -name '*.svelte' -o -name '*.jsx' -o -name '*.tsx' -o -name '*.vue' \) 2>/dev/null | grep -q .; then
        echo "true"
    else
        echo "false"
    fi
}

# Test 1: Svelte files detected
tmp1=$(mktemp -d)
mkdir -p "$tmp1/src/routes"
touch "$tmp1/src/routes/page.svelte"
result=$(detect_frontend_in "$tmp1")
assert "svelte detected" "[[ '$result' == 'true' ]]"
rm -rf "$tmp1"

# Test 2: TSX files detected
tmp2=$(mktemp -d)
mkdir -p "$tmp2/src/components"
touch "$tmp2/src/components/App.tsx"
result=$(detect_frontend_in "$tmp2")
assert "tsx detected" "[[ '$result' == 'true' ]]"
rm -rf "$tmp2"

# Test 3: Vue files detected
tmp3=$(mktemp -d)
mkdir -p "$tmp3/src"
touch "$tmp3/src/App.vue"
result=$(detect_frontend_in "$tmp3")
assert "vue detected" "[[ '$result' == 'true' ]]"
rm -rf "$tmp3"

# Test 4: No frontend files
tmp4=$(mktemp -d)
mkdir -p "$tmp4/cmd"
touch "$tmp4/cmd/main.go"
result=$(detect_frontend_in "$tmp4")
assert "no frontend files" "[[ '$result' == 'false' ]]"
rm -rf "$tmp4"

# Test 5: JSX files detected
tmp5=$(mktemp -d)
mkdir -p "$tmp5/src"
touch "$tmp5/src/App.jsx"
result=$(detect_frontend_in "$tmp5")
assert "jsx detected" "[[ '$result' == 'true' ]]"
rm -rf "$tmp5"

echo ""
echo "Results: $PASSED/$TESTS passed, $FAILED failed"
[[ $FAILED -eq 0 ]] || exit 1
