#!/usr/bin/env bash
# autopilot-detect-tools.sh — Detection helper functions for autopilot-detect-project.sh.
#
# Extracted from autopilot-detect-project.sh to keep files under 500 lines.
# Sourced by autopilot-detect-project.sh. Requires: REPO_ROOT set by caller.

set -euo pipefail

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

# ─── Secret Scanning Detection ───────────────────────────────────────────────

# Detect gitleaks and configure secret scanning.
# Sets PROJECT_SECRET_SCAN_CMD in the caller's environment.
detect_gitleaks() {
    if command -v gitleaks >/dev/null 2>&1; then
        PROJECT_SECRET_SCAN_CMD="gitleaks"
        echo "[INFO] Detected gitleaks — secret scanning enabled" >&2
        echo "[INFO] Tip: Add gitleaks pre-commit hook for local protection: https://github.com/gitleaks/gitleaks#pre-commit" >&2
    fi
}

# Generate a starter .gitleaks.toml if gitleaks is detected and no config exists.
_generate_gitleaks_config() {
    local repo_root="$1"
    [[ -f "$repo_root/.gitleaks.toml" ]] && return 0

    cat > "$repo_root/.gitleaks.toml" <<'GLTOML'
# Auto-generated by speckit-autopilot — extends gitleaks defaults
[extend]
useDefault = true

[[allowlists]]
  description = "Allowlist for known safe patterns"
  paths = [
    '''\.env\..*\.example$''',
    '''\.env\.example$''',
    '''fixtures/''',
    '''testdata/''',
  ]
  regexTarget = "line"
  regexes = [
    '''CHANGE_ME''',
    '''placeholder''',
    '''example\.com''',
    '''YOUR_.*_HERE''',
    '''AKIAIOSFODNN7EXAMPLE''',
    '''wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY''',
    '''sk_live_0{6,}''',
    '''sk_test_0{6,}''',
    '''ghp_0{6,}''',
  ]
GLTOML
    echo "[INFO] Generated .gitleaks.toml (review and commit)" >&2
}

# ─── Patch-mode helpers ─────────────────────────────────────────────────────

# Extract variable names (LHS of assignments) from a project.env file.
_extract_env_keys() {
    local file="$1"
    grep -oE '^[A-Za-z_][A-Za-z_0-9]*=' "$file" | sed 's/=$//' | sort -u
}

# Compare template vs existing env file; append missing variables.
_patch_env_file() {
    local existing="$1" template="$2"
    local existing_keys template_keys missing

    existing_keys=$(_extract_env_keys "$existing")
    template_keys=$(_extract_env_keys "$template")
    missing=$(comm -23 <(echo "$template_keys") <(echo "$existing_keys"))

    if [[ -z "$missing" ]]; then
        echo "project.env is up to date — no missing variables"
        return 0
    fi

    echo "" >> "$existing"
    echo "# ─── Added by --patch ($(date +%Y-%m-%d)) ──────────────────────────────" >> "$existing"

    while IFS= read -r key; do
        local line
        line=$(grep -m1 "^${key}=" "$template")
        if [[ -n "$line" ]]; then
            echo "$line" >> "$existing"
        fi
    done <<< "$missing"

    echo "Patched: added $(echo "$missing" | wc -l | tr -d ' ') missing variable(s)"
}

# Render the full project.env heredoc to a given file path.
# Relies on detected variables being in scope (called from detect-project.sh).
_render_env_template() {
    local target="$1"
    cat > "$target" <<EOF
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

# Codex review tier enabled (auto-mirrors HAS_CODEX; set to "false" to disable).
CODEX_ENABLED="$CODEX_ENABLED"

# CodeRabbit review max rounds per convergence loop.
CODERABBIT_MAX_ROUNDS=2
# REVIEW_TIER_ORDER=""    # Auto-detected. Override: cli,codex,self
# CODEX_REVIEW_TIMEOUT=300
# CODEX_MAX_DIFF_BYTES=800000
CODEX_MAX_ROUNDS=2
CLAUDE_SELF_REVIEW_MAX_ROUNDS=2

# Git remote origin exists (auto-detected).
HAS_REMOTE="$HAS_REMOTE"

# GitHub CLI (gh) available and authenticated (auto-detected).
HAS_GH_CLI="$HAS_GH_CLI"

# Frontend framework detected (auto-detected).
HAS_FRONTEND="$HAS_FRONTEND"


# Secret scanning (opt-in; requires gitleaks in PATH)
PROJECT_SECRET_SCAN_CMD="$PROJECT_SECRET_SCAN_CMD"
PROJECT_SECRET_TIER1_RULES=""
PROJECT_SECRET_SCAN_MODE="branch"

# All gate variables default to true (auto-advance). Use --strict to halt on failures.
# DIMINISHING_RETURNS_THRESHOLD=3

# Preflight tools required by this project (space-separated).
PROJECT_PREFLIGHT_TOOLS="$PREFLIGHT_TOOLS"

# Number of identical issue-count rounds before declaring stall. Default: 2.
CONVERGENCE_STALL_ROUNDS=2

# Merge strategy for epic branches: "merge" (default, --no-ff merge commit) or "squash" (one commit per epic).
MERGE_STRATEGY="merge"

# Detected project language (used by crystallize for module map extraction).
PROJECT_LANG="$detected"

# Stub enforcement level: error (hard-fail) | warn (log only) | off (skip detection).
STUB_ENFORCEMENT_LEVEL="warn"
EOF
}
