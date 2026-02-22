#!/usr/bin/env bash
# autopilot-verify.sh — Verification functions for the autopilot orchestrator
#
# Extracted from autopilot-lib.sh: test and lint verification with output capture.
#
# Sourced by autopilot-lib.sh. Requires: log() from autopilot-lib.sh.

set -euo pipefail

# ─── Verification ───────────────────────────────────────────────────────────

# Last captured test/lint output (set by verify_* functions for finalize prompts)
LAST_TEST_OUTPUT=""
LAST_LINT_OUTPUT=""

# Verify that tests pass. Returns 0 on success, 1 on failure.
# Side effect: sets LAST_TEST_OUTPUT with the captured output.
verify_tests() {
    local repo_root="$1"

    if [[ -z "$PROJECT_TEST_CMD" ]]; then
        log INFO "No test command configured — skipping"
        LAST_TEST_OUTPUT=""
        return 0
    fi

    log INFO "Running tests: $PROJECT_TEST_CMD"
    local tmpfile
    tmpfile=$(mktemp)
    local rc=0
    (cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_TEST_CMD") > "$tmpfile" 2>&1 || rc=$?
    LAST_TEST_OUTPUT=$(<"$tmpfile")
    rm -f "$tmpfile"

    if [[ $rc -eq 0 ]]; then
        log OK "Tests pass"
        return 0
    else
        log ERROR "Tests failed"
        return 1
    fi
}

# Verify linting passes. Returns 0 on success, 1 on failure.
# Side effect: sets LAST_LINT_OUTPUT with the captured output.
verify_lint() {
    local repo_root="$1"

    if [[ -z "$PROJECT_LINT_CMD" ]]; then
        log INFO "No lint command configured — skipping"
        LAST_LINT_OUTPUT=""
        return 0
    fi

    log INFO "Running lint: $PROJECT_LINT_CMD"
    local tmpfile
    tmpfile=$(mktemp)
    local rc=0
    (cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_LINT_CMD") > "$tmpfile" 2>&1 || rc=$?
    LAST_LINT_OUTPUT=$(<"$tmpfile")
    rm -f "$tmpfile"

    if [[ $rc -eq 0 ]]; then
        log OK "Lint clean"
        return 0
    else
        log ERROR "Lint issues found"
        return 1
    fi
}
