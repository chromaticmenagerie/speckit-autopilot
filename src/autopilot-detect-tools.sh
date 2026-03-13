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
