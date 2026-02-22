#!/usr/bin/env bash
# autopilot-detect-project.sh — Auto-detect project tooling and generate .specify/project.env
#
# Scans the repo root for ecosystem markers (pyproject.toml, package.json,
# Cargo.toml, go.mod, Makefile) and writes sensible defaults for test/lint
# commands. Run during project setup; autopilot requires project.env to exist.
#
# Usage:
#   ./autopilot-detect-project.sh           # Generate if missing
#   ./autopilot-detect-project.sh --force   # Overwrite existing

set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

REPO_ROOT="$(get_repo_root)"
ENV_FILE="$REPO_ROOT/.specify/project.env"
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        -h|--help)
            echo "Usage: autopilot-detect-project.sh [--force]"
            echo "  Detects project tooling and writes .specify/project.env"
            exit 0
            ;;
    esac
done

if [[ -f "$ENV_FILE" ]] && [[ "$FORCE" != true ]]; then
    echo "project.env already exists at $ENV_FILE"
    echo "Use --force to overwrite."
    exit 0
fi


# Ensure .specify/logs/ is gitignored in target repo.
# Idempotent: safe to call multiple times.
_ensure_gitignore_logs() {
    local repo_root="$1"
    local gitignore="$repo_root/.gitignore"

    if [[ ! -f "$gitignore" ]]; then
        echo ".specify/logs/" > "$gitignore"
        return 0
    fi

    if ! grep -qxF '.specify/logs/' "$gitignore"; then
        echo '.specify/logs/' >> "$gitignore"
    fi
}
# ─── Detection ───────────────────────────────────────────────────────────────

TEST_CMD=""
LINT_CMD=""
WORK_DIR="."
BUILD_CMD=""
FORMAT_CMD=""
PREFLIGHT_TOOLS=""

detect_python() {
    if [[ -f "$REPO_ROOT/pyproject.toml" ]] || [[ -f "$REPO_ROOT/setup.py" ]]; then
        TEST_CMD="python3 -m pytest"
        # Check for ruff first, then flake8
        if grep -q "ruff" "$REPO_ROOT/pyproject.toml" 2>/dev/null || command -v ruff >/dev/null 2>&1; then
            LINT_CMD="ruff check ."
            FORMAT_CMD="ruff format ."
            PREFLIGHT_TOOLS="ruff pytest"
        elif command -v flake8 >/dev/null 2>&1; then
            LINT_CMD="flake8 ."
            PREFLIGHT_TOOLS="flake8 pytest"
        fi
        return 0
    fi
    return 1
}

detect_node() {
    if [[ -f "$REPO_ROOT/package.json" ]]; then
        TEST_CMD="npm test"
        LINT_CMD="npm run lint"
        PREFLIGHT_TOOLS="eslint"
        return 0
    fi
    return 1
}

detect_rust() {
    if [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
        TEST_CMD="cargo test"
        LINT_CMD="cargo clippy -- -D warnings"
        BUILD_CMD="cargo build"
        FORMAT_CMD="cargo fmt --check"
        PREFLIGHT_TOOLS="cargo"
        return 0
    fi
    return 1
}

detect_go() {
    if [[ -f "$REPO_ROOT/go.mod" ]]; then
        TEST_CMD="go test ./..."
        LINT_CMD="golangci-lint run"
        BUILD_CMD="go build ./..."
        FORMAT_CMD="gofmt -l ."
        PREFLIGHT_TOOLS="golangci-lint"
        return 0
    fi
    return 1
}

detect_makefile() {
    if [[ -f "$REPO_ROOT/Makefile" ]]; then
        grep -q "^test:" "$REPO_ROOT/Makefile" && TEST_CMD="make test"
        grep -q "^lint:" "$REPO_ROOT/Makefile" && LINT_CMD="make lint"
        grep -q "^build:" "$REPO_ROOT/Makefile" && BUILD_CMD="make build"
        if grep -q "^fmt:" "$REPO_ROOT/Makefile"; then
            FORMAT_CMD="make fmt"
        elif grep -q "^format:" "$REPO_ROOT/Makefile"; then
            FORMAT_CMD="make format"
        fi
        return 0
    fi
    return 1
}

# Detect the base branch (main or master)
detect_base_branch() {
    local branch
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    if [[ -z "$branch" ]]; then
        if git rev-parse --verify main >/dev/null 2>&1; then
            branch="main"
        elif git rev-parse --verify master >/dev/null 2>&1; then
            branch="master"
        else
            branch="main"
        fi
    fi
    echo "$branch"
}

# Detect CodeRabbit CLI
detect_coderabbit_cli() {
    if command -v coderabbit >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Detect git remote origin
detect_remote() {
    if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Detect GitHub CLI (authenticated)
detect_gh_cli() {
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Try detectors in priority order (first match wins)
detected="unknown"
if detect_python; then
    detected="Python"
elif detect_node; then
    detected="Node/JS/TS"
elif detect_rust; then
    detected="Rust"
elif detect_go; then
    detected="Go"
elif detect_makefile; then
    detected="Makefile"
fi

BASE_BRANCH=$(detect_base_branch)

# Capability detection
HAS_CODERABBIT="false"
HAS_REMOTE="false"
HAS_GH_CLI="false"
detect_coderabbit_cli && HAS_CODERABBIT="true"
detect_remote && HAS_REMOTE="true"
detect_gh_cli && HAS_GH_CLI="true"

# ─── Write ───────────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$ENV_FILE")"

cat > "$ENV_FILE" <<EOF
# .specify/project.env — Project tooling config for autopilot
# Generated by: autopilot-detect-project.sh (detected: $detected)
# Override any value by editing directly. Re-run with --force to regenerate.

# Command to run the full test suite. Must exit 0 on success.
PROJECT_TEST_CMD="$TEST_CMD"

# Command to run the linter. Must exit 0 on no issues.
PROJECT_LINT_CMD="$LINT_CMD"

# Directory to cd into before running commands (relative to repo root).
PROJECT_WORK_DIR="$WORK_DIR"

# Build command (empty = no build step).
PROJECT_BUILD_CMD="$BUILD_CMD"

# Auto-format command (empty = no formatter).
PROJECT_FORMAT_CMD="$FORMAT_CMD"

# Base branch for merges (auto-detected).
BASE_BRANCH="$BASE_BRANCH"

# CodeRabbit CLI available (auto-detected).
HAS_CODERABBIT="$HAS_CODERABBIT"

# Git remote origin exists (auto-detected).
HAS_REMOTE="$HAS_REMOTE"

# GitHub CLI (gh) available and authenticated (auto-detected).
HAS_GH_CLI="$HAS_GH_CLI"

# Force-advance past CodeRabbit CLI review failures instead of halting.
# Set to "true" to keep the old behavior (always advance). Default: "false" (halt on failure).
FORCE_ADVANCE_ON_REVIEW_FAIL="false"

# Preflight tools required by this project (space-separated).
PROJECT_PREFLIGHT_TOOLS="$PREFLIGHT_TOOLS"

# Number of identical issue-count rounds before declaring stall. Default: 2.
CONVERGENCE_STALL_ROUNDS=2
EOF

_ensure_gitignore_logs "$REPO_ROOT"
echo "Detected: $detected"
echo "Written:  $ENV_FILE"
echo ""
echo "  TEST_CMD:    ${TEST_CMD:-"(none)"}"
echo "  LINT_CMD:    ${LINT_CMD:-"(none)"}"
echo "  WORK_DIR:    $WORK_DIR"
echo "  BUILD_CMD:   ${BUILD_CMD:-"(none)"}"
echo "  FORMAT_CMD:  ${FORMAT_CMD:-"(none)"}"
echo "  BASE_BRANCH: $BASE_BRANCH"
echo "  CODERABBIT: ${HAS_CODERABBIT}"
echo "  REMOTE:     ${HAS_REMOTE}"
echo "  GH_CLI:     ${HAS_GH_CLI}"
echo "  PREFLIGHT:  ${PREFLIGHT_TOOLS:-"(none)"}"
echo ""
echo "Review and adjust as needed, then commit to git."

# Generate .coderabbit.yaml if CodeRabbit is available and config missing
if [[ "$HAS_CODERABBIT" == "true" ]] && [[ ! -f "$REPO_ROOT/.coderabbit.yaml" ]]; then
    cat > "$REPO_ROOT/.coderabbit.yaml" <<'CRYAML'
# .coderabbit.yaml — CodeRabbit configuration (generated by autopilot)
language: en
reviews:
  profile: assertive
  request_changes_workflow: true
  high_level_summary: true
  poem: false
  review_status: true
  path_instructions: []
  auto_review:
    enabled: true
    drafts: false
  tools:
    shellcheck:
      enabled: true
    ruff:
      enabled: true
    biome:
      enabled: true
    hadolint:
      enabled: true
    markdownlint:
      enabled: true
    github-checks:
      enabled: true
      timeout_ms: 90000
chat:
  auto_reply: true
CRYAML
    echo ""
    echo "Generated: .coderabbit.yaml (review and commit)"
fi
