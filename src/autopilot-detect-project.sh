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

detect_node_monorepo() {
    # Must have package.json
    [[ -f "$REPO_ROOT/package.json" ]] || return 1

    # Must be a workspace root (package.json "workspaces" or pnpm-workspace.yaml)
    local is_workspace=false
    if grep -q '"workspaces"' "$REPO_ROOT/package.json" 2>/dev/null; then
        is_workspace=true
    elif [[ -f "$REPO_ROOT/pnpm-workspace.yaml" ]]; then
        is_workspace=true
    fi
    [[ "$is_workspace" == "true" ]] || return 1

    # Must have Makefile with BOTH test: and lint: targets
    [[ -f "$REPO_ROOT/Makefile" ]] || return 1
    grep -q "^test:" "$REPO_ROOT/Makefile" || return 1
    grep -q "^lint:" "$REPO_ROOT/Makefile" || return 1

    TEST_CMD="make test"
    LINT_CMD="make lint"
    grep -q "^build:" "$REPO_ROOT/Makefile" && BUILD_CMD="make build"
    if grep -q "^fmt:" "$REPO_ROOT/Makefile"; then
        FORMAT_CMD="make fmt"
    elif grep -q "^format:" "$REPO_ROOT/Makefile"; then
        FORMAT_CMD="make format"
    fi
    PREFLIGHT_TOOLS="make"
    return 0
}
detect_node() {
    if [[ -f "$REPO_ROOT/package.json" ]]; then
        TEST_CMD="npm test"
        LINT_CMD="npm run lint"
        grep -q '"check"' "$REPO_ROOT/package.json" 2>/dev/null && BUILD_CMD="npm run check"
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
elif detect_node_monorepo; then
    detected="Node-Monorepo"
elif detect_node; then
    detected="Node/JS/TS"
elif detect_rust; then
    detected="Rust"
elif detect_go; then
    detected="Go"
elif detect_makefile; then
    detected="Makefile"
fi

# ─── CI Capability Detection ─────────────────────────────────────────────────

# CI target: prefer ci-local, fall back to ci
ci_cmd=""
if [[ -f "$REPO_ROOT/Makefile" ]]; then
    if grep -q "^ci-local:" "$REPO_ROOT/Makefile"; then
        ci_cmd="make ci-local"
    elif grep -q "^ci:" "$REPO_ROOT/Makefile"; then
        ci_cmd="make ci"
    fi
fi

# Frontend package manager + directory detection
fe_pkg_manager="" fe_dir="" fe_install_cmd=""
# Check root first, then common subdirs
for candidate_dir in "." "frontend" "web" "client" "app"; do
    check_dir="$REPO_ROOT/$candidate_dir"
    [[ "$candidate_dir" == "." ]] && check_dir="$REPO_ROOT"
    if [[ -f "$check_dir/pnpm-lock.yaml" ]]; then
        fe_pkg_manager="pnpm"
        fe_dir="$candidate_dir"
        fe_install_cmd="pnpm install --frozen-lockfile"
        break
    elif [[ -f "$check_dir/package-lock.json" ]]; then
        fe_pkg_manager="npm"
        fe_dir="$candidate_dir"
        fe_install_cmd="npm ci"
        break
    fi
done
# Normalize root dir
[[ "$fe_dir" == "." ]] && fe_dir=""

# Format check (read-only, no writes)
fmt_check_cmd=""
if [[ -f "$REPO_ROOT/go.mod" ]] || [[ -f "$REPO_ROOT/backend/go.mod" ]]; then
    go_dir="."
    [[ -f "$REPO_ROOT/backend/go.mod" ]] && go_dir="backend"
    fmt_check_cmd="cd ${go_dir} && gofmt -l . | (! grep .)"
fi
# Append prettier check if frontend has prettier
if [[ -n "$fe_dir" ]] && [[ -f "$REPO_ROOT/$fe_dir/.prettierrc" || -f "$REPO_ROOT/$fe_dir/.prettierrc.json" || -f "$REPO_ROOT/$fe_dir/.prettierrc.js" || -f "$REPO_ROOT/$fe_dir/.prettierrc.yaml" || -f "$REPO_ROOT/$fe_dir/prettier.config.js" ]]; then
    prettier_cmd="cd ${fe_dir} && npx prettier --check ."
    if [[ -n "$fmt_check_cmd" ]]; then
        fmt_check_cmd="${fmt_check_cmd} && ${prettier_cmd}"
    else
        fmt_check_cmd="$prettier_cmd"
    fi
elif [[ -z "$fe_dir" ]] && [[ -f "$REPO_ROOT/.prettierrc" || -f "$REPO_ROOT/.prettierrc.json" ]]; then
    prettier_cmd="npx prettier --check ."
    if [[ -n "$fmt_check_cmd" ]]; then
        fmt_check_cmd="${fmt_check_cmd} && ${prettier_cmd}"
    else
        fmt_check_cmd="$prettier_cmd"
    fi
fi

# Codegen staleness check
codegen_check_cmd=""
if [[ -f "$REPO_ROOT/Makefile" ]]; then
    if grep -q "^check-generate:" "$REPO_ROOT/Makefile"; then
        codegen_check_cmd="make check-generate"
    elif grep -q "^generate:" "$REPO_ROOT/Makefile"; then
        codegen_check_cmd="make generate && git diff --exit-code"
    fi
fi

# Integration tests
integration_cmd=""
if [[ -f "$REPO_ROOT/Makefile" ]]; then
    if grep -q "^test-integration:" "$REPO_ROOT/Makefile"; then
        integration_cmd="make test-integration"
    elif grep -q "^test/go/integration:" "$REPO_ROOT/Makefile"; then
        integration_cmd="make test/go/integration"
    fi
fi

# E2E tests — require both a Makefile target AND a playwright config
e2e_cmd=""
if [[ -f "$REPO_ROOT/Makefile" ]]; then
    has_e2e_target=false
    grep -q "^test-e2e:" "$REPO_ROOT/Makefile" && has_e2e_target=true
    grep -q "^test/e2e:" "$REPO_ROOT/Makefile" && has_e2e_target=true
    if $has_e2e_target; then
        # Verify playwright config exists somewhere
        pw_found=false
        for pw_dir in "$REPO_ROOT" "$REPO_ROOT/$fe_dir"; do
            [[ -f "$pw_dir/playwright.config.ts" || -f "$pw_dir/playwright.config.js" ]] && pw_found=true && break
        done
        if $pw_found; then
            if grep -q "^test-e2e:" "$REPO_ROOT/Makefile"; then
                e2e_cmd="make test-e2e"
            else
                e2e_cmd="make test/e2e"
            fi
        fi
    fi
fi

# Docker availability (with portable timeout for macOS — docker info can hang
# indefinitely when Docker Desktop is in "Starting..." state).
# Uses perl alarm as portable timeout (perl ships with macOS; GNU timeout does not).
# Lets Docker CLI find its own socket (respects $DOCKER_HOST, Docker contexts,
# platform defaults) — do NOT hardcode /var/run/docker.sock as it fails for
# Colima, OrbStack, and Docker Desktop 4.18+ without legacy socket enabled.
has_docker="false"
if command -v docker >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' 5 docker info >/dev/null 2>&1 && has_docker="true"
fi

BASE_BRANCH=$(detect_base_branch)

# Capability detection
HAS_CODERABBIT="false"
HAS_REMOTE="false"
HAS_GH_CLI="false"
detect_coderabbit_cli && HAS_CODERABBIT="true"
HAS_CODEX="false"
command -v codex &>/dev/null && HAS_CODEX="true"
detect_remote && HAS_REMOTE="true"
detect_gh_cli && HAS_GH_CLI="true"

HAS_FRONTEND="false"
if find "$REPO_ROOT" -maxdepth 4 \( -name '*.svelte' -o -name '*.jsx' -o -name '*.tsx' -o -name '*.vue' \) 2>/dev/null | grep -q .; then
    HAS_FRONTEND="true"
fi

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

# Full CI pipeline command (existing ci-local: or ci: target).
# If set, verify-ci uses this directly. If empty, composes pipeline from capabilities below.
PROJECT_CI_CMD="$ci_cmd"

# Format check — read-only, no file writes (used by composed CI pipeline).
PROJECT_FMT_CHECK_CMD="$fmt_check_cmd"

# Codegen staleness check (used by composed CI pipeline).
PROJECT_CODEGEN_CHECK_CMD="$codegen_check_cmd"

# Integration test command (used by composed CI pipeline; skipped if Docker unavailable).
PROJECT_INTEGRATION_CMD="$integration_cmd"

# E2E test command (used by composed CI pipeline; skipped if services not running).
PROJECT_E2E_CMD="$e2e_cmd"

# Frontend package manager: "npm" or "pnpm" (auto-detected from lockfile).
PROJECT_FE_PKG_MANAGER="$fe_pkg_manager"

# Frontend directory relative to repo root (empty = root).
PROJECT_FE_DIR="$fe_dir"

# Frontend dependency install command (frozen lockfile).
PROJECT_FE_INSTALL_CMD="$fe_install_cmd"

# Docker daemon available at detection time.
HAS_DOCKER="$has_docker"

# Base branch for merges (auto-detected).
BASE_BRANCH="$BASE_BRANCH"

# CodeRabbit CLI available (auto-detected).
HAS_CODERABBIT="$HAS_CODERABBIT"

# Codex CLI available (auto-detected).
HAS_CODEX="$HAS_CODEX"

# CodeRabbit review max rounds per convergence loop.
CODERABBIT_MAX_ROUNDS=3
# REVIEW_TIER_ORDER=""    # Auto-detected. Override: cli,codex,self
# CODEX_REVIEW_TIMEOUT=300
# CODEX_MAX_DIFF_BYTES=800000
# CODEX_MAX_ROUNDS=3
# CLAUDE_SELF_REVIEW_MAX_ROUNDS=2

# Git remote origin exists (auto-detected).
HAS_REMOTE="$HAS_REMOTE"

# GitHub CLI (gh) available and authenticated (auto-detected).
HAS_GH_CLI="$HAS_GH_CLI"

# Frontend framework detected (auto-detected).
HAS_FRONTEND="$HAS_FRONTEND"

# Force-advance past CodeRabbit CLI review stalls (same issue count for N rounds).
# Default: "false" (halt on stalls). Set to "true" to force-advance past stalls.
FORCE_ADVANCE_ON_REVIEW_STALL="false"

# Force-advance when review improvements diminish (issue count drops but not to zero).
# Default: "false" (halt on diminishing returns). Set to "true" to force-advance.
FORCE_ADVANCE_ON_DIMINISHING_RETURNS="false"

# Force-advance past CodeRabbit CLI review errors (issues remain after max rounds).
# Default: "false" (halt on errors). Set to "true" to force-advance past errors.
FORCE_ADVANCE_ON_REVIEW_ERROR="false"

# Deprecated: use FORCE_ADVANCE_ON_REVIEW_STALL, FORCE_ADVANCE_ON_DIMINISHING_RETURNS, and FORCE_ADVANCE_ON_REVIEW_ERROR above.
# FORCE_ADVANCE_ON_REVIEW_FAIL="true"

# Preflight tools required by this project (space-separated).
PROJECT_PREFLIGHT_TOOLS="$PREFLIGHT_TOOLS"

# Number of identical issue-count rounds before declaring stall. Default: 2.
CONVERGENCE_STALL_ROUNDS=2

# Merge strategy for epic branches: "merge" (default, --no-ff merge commit) or "squash" (one commit per epic).
MERGE_STRATEGY="merge"
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
echo "  HAS_FRONTEND=$HAS_FRONTEND"
echo "  PREFLIGHT:  ${PREFLIGHT_TOOLS:-"(none)"}"
echo "  CI_CMD:      ${ci_cmd:-"(none — will compose)"}"
echo "  FMT_CHECK:   ${fmt_check_cmd:-"(none)"}"
echo "  CODEGEN:     ${codegen_check_cmd:-"(none)"}"
echo "  INTEGRATION: ${integration_cmd:-"(none)"}"
echo "  E2E:         ${e2e_cmd:-"(none)"}"
echo "  FE_PKG:      ${fe_pkg_manager:-"(none)"}"
echo "  FE_DIR:      ${fe_dir:-"(root)"}"
echo "  DOCKER:      ${has_docker}"
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
