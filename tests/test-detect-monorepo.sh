#!/usr/bin/env bash
# test-detect-monorepo.sh — Unit tests for detect_node_monorepo()
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

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub log and other externals
log() { :; }

# Extract detection functions from detect-project
extract_func() {
    local func="$1"
    sed -n "/^${func}()/,/^}/p" "$SRC_DIR/autopilot-detect-project.sh"
}

eval "$(extract_func detect_node_monorepo)"
eval "$(extract_func detect_node)"
eval "$(extract_func detect_makefile)"

# Helper: reset detection vars
reset_vars() {
    TEST_CMD=""
    LINT_CMD=""
    BUILD_CMD=""
    FORMAT_CMD=""
    PREFLIGHT_TOOLS=""
}

# Helper: run detection chain inline (no subshell, so vars propagate)
run_detection_chain() {
    detected="unknown"
    if detect_node_monorepo; then
        detected="Node-Monorepo"
    elif detect_node; then
        detected="Node/JS/TS"
    elif detect_makefile; then
        detected="Makefile"
    fi
}

# ─── Test 1: Monorepo match ────────────────────────────────────────────────

echo "Test 1: package.json with workspaces + Makefile(test+lint) → Node-Monorepo"

reset_vars
REPO_ROOT="$TMPDIR/test1"
mkdir -p "$REPO_ROOT"
cat > "$REPO_ROOT/package.json" <<'EOF'
{ "name": "mono", "workspaces": ["packages/*"] }
EOF
cat > "$REPO_ROOT/Makefile" <<'EOF'
test:
	npm run test --workspaces
lint:
	npm run lint --workspaces
EOF

run_detection_chain
assert_eq "Node-Monorepo" "$detected" "detected=Node-Monorepo"
assert_eq "make test" "$TEST_CMD" "TEST_CMD=make test"
assert_eq "make lint" "$LINT_CMD" "LINT_CMD=make lint"
assert_eq "make" "$PREFLIGHT_TOOLS" "PREFLIGHT_TOOLS=make"

# ─── Test 2: Monorepo no Makefile lint → falls through to Node ─────────────

echo "Test 2: workspaces + Makefile(test only, no lint) → falls through to Node"

reset_vars
REPO_ROOT="$TMPDIR/test2"
mkdir -p "$REPO_ROOT"
cat > "$REPO_ROOT/package.json" <<'EOF'
{ "name": "mono", "workspaces": ["packages/*"] }
EOF
cat > "$REPO_ROOT/Makefile" <<'EOF'
test:
	echo "test"
EOF

run_detection_chain
assert_eq "Node/JS/TS" "$detected" "detected=Node/JS/TS (fallthrough)"
assert_eq "npm test" "$TEST_CMD" "TEST_CMD=npm test"
assert_eq "npm run lint" "$LINT_CMD" "LINT_CMD=npm run lint"

# ─── Test 3: Plain Node (no workspaces) → Node ────────────────────────────

echo "Test 3: package.json without workspaces + Makefile → Node (not monorepo)"

reset_vars
REPO_ROOT="$TMPDIR/test3"
mkdir -p "$REPO_ROOT"
cat > "$REPO_ROOT/package.json" <<'EOF'
{ "name": "plain-node", "scripts": { "test": "jest" } }
EOF
cat > "$REPO_ROOT/Makefile" <<'EOF'
test:
	npm test
lint:
	npm run lint
EOF

run_detection_chain
assert_eq "Node/JS/TS" "$detected" "detected=Node/JS/TS (plain node)"
assert_eq "npm test" "$TEST_CMD" "TEST_CMD=npm test"

# ─── Test 4: pnpm monorepo ────────────────────────────────────────────────

echo "Test 4: pnpm-workspace.yaml + Makefile(test+lint) → Node-Monorepo"

reset_vars
REPO_ROOT="$TMPDIR/test4"
mkdir -p "$REPO_ROOT"
cat > "$REPO_ROOT/package.json" <<'EOF'
{ "name": "pnpm-mono" }
EOF
cat > "$REPO_ROOT/pnpm-workspace.yaml" <<'EOF'
packages:
  - 'packages/*'
EOF
cat > "$REPO_ROOT/Makefile" <<'EOF'
test:
	pnpm test --recursive
lint:
	pnpm lint --recursive
EOF

run_detection_chain
assert_eq "Node-Monorepo" "$detected" "detected=Node-Monorepo (pnpm)"
assert_eq "make test" "$TEST_CMD" "TEST_CMD=make test"
assert_eq "make lint" "$LINT_CMD" "LINT_CMD=make lint"

# ─── Test 5: Monorepo with build/format targets ───────────────────────────

echo "Test 5: workspaces + Makefile(test+lint+build+fmt) → extra cmds set"

reset_vars
REPO_ROOT="$TMPDIR/test5"
mkdir -p "$REPO_ROOT"
cat > "$REPO_ROOT/package.json" <<'EOF'
{ "name": "full-mono", "workspaces": ["packages/*"] }
EOF
cat > "$REPO_ROOT/Makefile" <<'EOF'
test:
	echo test
lint:
	echo lint
build:
	echo build
fmt:
	echo fmt
EOF

run_detection_chain
assert_eq "Node-Monorepo" "$detected" "detected=Node-Monorepo"
assert_eq "make build" "$BUILD_CMD" "BUILD_CMD=make build"
assert_eq "make fmt" "$FORMAT_CMD" "FORMAT_CMD=make fmt"

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
