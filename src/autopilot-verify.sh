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
LAST_BUILD_OUTPUT=""

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

    if [[ $rc -ne 0 ]]; then
        log ERROR "Tests failed"
        return 1
    fi

    # Detect t.Skip() / t.Skipf() / t.SkipNow() stubs in test files
    local skip_files=""
    skip_files=$(grep -rlE 't\.Skip(f|Now)?\(' "$repo_root/$PROJECT_WORK_DIR" --include='*_test.go' --exclude-dir=vendor --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=third_party 2>/dev/null || true)
    if [[ -n "$skip_files" ]]; then
        local skip_count
        skip_count=$(echo "$skip_files" | wc -l | tr -d ' ')
        log ERROR "Found $skip_count test file(s) with t.Skip() stubs:"
        echo "$skip_files" | while read -r f; do
            log ERROR "  - $f"
        done
        return 1
    fi

    log OK "Tests pass"
    return 0
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

# Verify that the project builds. Returns 0 on success, 1 on failure.
# Side effect: sets LAST_BUILD_OUTPUT with the captured output.
verify_build() {
    local repo_root="$1"

    if [[ -z "$PROJECT_BUILD_CMD" ]]; then
        log INFO "No build command configured — skipping"
        LAST_BUILD_OUTPUT=""
        return 0
    fi

    log INFO "Running build: $PROJECT_BUILD_CMD"
    local tmpfile
    tmpfile=$(mktemp)
    local rc=0
    (cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_BUILD_CMD") > "$tmpfile" 2>&1 || rc=$?
    LAST_BUILD_OUTPUT=$(<"$tmpfile")
    rm -f "$tmpfile"

    if [[ $rc -eq 0 ]]; then
        log OK "Build clean"
        return 0
    else
        log WARN "Build failed"
        return 1
    fi
}

LAST_CI_OUTPUT=""
CI_FIX_WARNINGS=""

verify_ci() {
    local repo_root="$1"
    local tmpfile rc=0
    tmpfile=$(mktemp)

    # Path A: Repo has its own CI target — use it
    if [[ -n "${PROJECT_CI_CMD:-}" ]]; then
        log INFO "Running repo CI: $PROJECT_CI_CMD"
        (cd "$repo_root" && eval "$PROJECT_CI_CMD") > "$tmpfile" 2>&1 || rc=$?
        _capture_ci_output "$tmpfile"
        rm -f "$tmpfile"
        [[ $rc -eq 0 ]] && { log OK "Repo CI passed"; return 0; }
        log ERROR "Repo CI failed (exit $rc)"; return 1
    fi

    # Path B: Compose pipeline from detected capabilities
    log INFO "Composing CI pipeline from detected capabilities"

    # Step 1: Frontend dependency install (if needed)
    if [[ -n "${PROJECT_FE_INSTALL_CMD:-}" ]] && [[ -n "${PROJECT_FE_DIR:-}" ]]; then
        local fe_abs="$repo_root/$PROJECT_FE_DIR"
        local needs_install=false
        if [[ ! -d "$fe_abs/node_modules" ]]; then
            needs_install=true
        elif [[ -f "$fe_abs/package-lock.json" && "$fe_abs/package-lock.json" -nt "$fe_abs/node_modules" ]]; then
            needs_install=true
        elif [[ -f "$fe_abs/pnpm-lock.yaml" ]]; then
            # For pnpm: compare against .pnpm/lock.yaml (pnpm's internal copy of the lockfile,
            # whose mtime reflects last install time). More reliable than comparing against the
            # node_modules/ directory mtime which can be bumped by IDE/editor background processes.
            # If .pnpm/lock.yaml is missing (fresh clone or future pnpm version), always install.
            if [[ ! -f "$fe_abs/node_modules/.pnpm/lock.yaml" ]] || \
               [[ "$fe_abs/pnpm-lock.yaml" -nt "$fe_abs/node_modules/.pnpm/lock.yaml" ]]; then
                needs_install=true
            fi
        fi
        if $needs_install; then
            _run_ci_step "$repo_root" "Frontend Dependencies" \
                "cd ${PROJECT_FE_DIR:-.} && ${PROJECT_FE_INSTALL_CMD}" "$tmpfile" || {
                _capture_ci_output "$tmpfile"; rm -f "$tmpfile"; return 1
            }
        fi
    fi

    # Step 2: Format check
    if [[ -n "${PROJECT_FMT_CHECK_CMD:-}" ]]; then
        _run_ci_step "$repo_root" "Format Check" "$PROJECT_FMT_CHECK_CMD" "$tmpfile" || {
            _capture_ci_output "$tmpfile"; rm -f "$tmpfile"; return 1
        }
    fi

    # Step 3: Codegen staleness check
    if [[ -n "${PROJECT_CODEGEN_CHECK_CMD:-}" ]]; then
        _run_ci_step "$repo_root" "Codegen Staleness" "$PROJECT_CODEGEN_CHECK_CMD" "$tmpfile" || {
            _capture_ci_output "$tmpfile"; rm -f "$tmpfile"; return 1
        }
    fi

    # Step 4: Lint
    if ! verify_lint "$repo_root"; then
        LAST_CI_OUTPUT="=== STEP: Lint === FAIL"$'\n'"$LAST_LINT_OUTPUT"
        rm -f "$tmpfile"; return 1
    fi

    # Step 5: Unit tests
    if ! verify_tests "$repo_root"; then
        LAST_CI_OUTPUT="=== STEP: Tests === FAIL"$'\n'"$LAST_TEST_OUTPUT"
        rm -f "$tmpfile"; return 1
    fi

    # Step 6: Integration tests (only if Docker available)
    if [[ -n "${PROJECT_INTEGRATION_CMD:-}" ]]; then
        if command -v docker >/dev/null 2>&1 && \
           perl -e 'alarm shift; exec @ARGV' 5 docker info >/dev/null 2>&1; then
            _run_ci_step "$repo_root" "Integration Tests" "$PROJECT_INTEGRATION_CMD" "$tmpfile" || {
                _capture_ci_output "$tmpfile"; rm -f "$tmpfile"; return 1
            }
        else
            log INFO "Docker not available — skipping integration tests"
        fi
    fi

    # Step 7: Build
    if ! verify_build "$repo_root"; then
        LAST_CI_OUTPUT="=== STEP: Build === FAIL"$'\n'"$LAST_BUILD_OUTPUT"
        rm -f "$tmpfile"; return 1
    fi

    # Step 8: E2E (conditional — only if services are running)
    if [[ -n "${PROJECT_E2E_CMD:-}" ]]; then
        if _check_e2e_services "$repo_root"; then
            _run_ci_step "$repo_root" "E2E Tests" "$PROJECT_E2E_CMD" "$tmpfile" || {
                _capture_ci_output "$tmpfile"; rm -f "$tmpfile"; return 1
            }
        else
            log INFO "E2E services not running — skipping (start with: make dev)"
        fi
    fi

    log OK "All CI checks passed (composed pipeline)"
    rm -f "$tmpfile"
    return 0
}

# Helper: run a single CI step with output capture
_run_ci_step() {
    local repo_root="$1" step_name="$2" cmd="$3" tmpfile="$4"
    log INFO "=== STEP: $step_name ==="
    local rc=0
    (cd "$repo_root" && eval "$cmd") >> "$tmpfile" 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then
        log ERROR "$step_name failed (exit $rc)"
        return 1
    fi
    return 0
}

# Helper: capture and truncate CI output
_capture_ci_output() {
    local tmpfile="$1"
    LAST_CI_OUTPUT=$(<"$tmpfile")
    if [[ ${#LAST_CI_OUTPUT} -gt 8000 ]]; then
        LAST_CI_OUTPUT="[...truncated — showing last 8000 chars...]"$'\n'"${LAST_CI_OUTPUT: -8000}"
    fi
}

# Helper: check if E2E services are running
_check_e2e_services() {
    local repo_root="$1"
    local health_ok=false
    for path in /health /api/health /api/v1/health /v1/health; do
        if curl -sf --connect-timeout 2 --max-time 5 \
            "http://localhost:8080${path}" >/dev/null 2>&1; then
            health_ok=true; break
        fi
    done
    $health_ok || return 1
    curl -sf --connect-timeout 2 --max-time 5 http://localhost:5173 >/dev/null 2>&1 || \
        curl -sf --connect-timeout 2 --max-time 5 http://localhost:4173 >/dev/null 2>&1 || return 1
    return 0
}

# Helper: detect test file modifications after a CI fix round
# Sets CI_FIX_TEST_WARN with details if test files were modified
_detect_test_modifications() {
    local repo_root="$1" head_before="$2"
    CI_FIX_TEST_WARN=""

    # Check committed changes
    local modified_tests
    modified_tests=$(git -C "$repo_root" diff --name-only "$head_before"..HEAD | \
        grep -E '_test\.(go|ts|js|py)$|\.test\.(ts|js)$|\.spec\.(ts|js)$' || true)

    # Also check uncommitted changes (staged + unstaged)
    local dirty_tests
    dirty_tests=$(git -C "$repo_root" diff --name-only HEAD | \
        grep -E '_test\.(go|ts|js|py)$|\.test\.(ts|js)$|\.spec\.(ts|js)$' || true)

    local all_tests="${modified_tests}${dirty_tests:+$'\n'$dirty_tests}"
    [[ -z "$all_tests" ]] && return 0

    # Count assertion additions vs deletions using aggregate diff
    # Uses expanded pathspecs to include testutil helper files (prevents false halts
    # when assertions are extracted to shared helpers like testutil/assertions.go).
    # Aggregate counting across all files handles renames and cross-file moves correctly.
    local assertion_added=0 assertion_removed=0
    if [[ -n "$all_tests" ]]; then
        assertion_added=$(git -C "$repo_root" diff "$head_before"..HEAD -- \
            '*_test.go' '*.test.ts' '*.test.js' '*.spec.ts' '*.spec.js' \
            '**/testutil/*.go' '**/test_helpers/*.go' | \
            grep -cE '^\+.*(assert\.|require\.|expect\(|t\.(Fatal|Fatalf|Error|Errorf|FailNow)\()' || true)
        assertion_removed=$(git -C "$repo_root" diff "$head_before"..HEAD -- \
            '*_test.go' '*.test.ts' '*.test.js' '*.spec.ts' '*.spec.js' \
            '**/testutil/*.go' '**/test_helpers/*.go' | \
            grep -cE '^\-.*(assert\.|require\.|expect\(|t\.(Fatal|Fatalf|Error|Errorf|FailNow)\()' || true)
    fi

    if [[ "$assertion_removed" -gt "$assertion_added" ]]; then
        CI_FIX_TEST_WARN="ERROR: Net assertion deletion in: $all_tests (added=$assertion_added, removed=$assertion_removed)"
        log ERROR "CI-fix has net assertion DELETION in: $all_tests (added=$assertion_added removed=$assertion_removed)"
    elif [[ "$assertion_added" -gt 0 || "$assertion_removed" -gt 0 ]]; then
        CI_FIX_TEST_WARN="WARN: Assertion changes in: $all_tests (added=$assertion_added, removed=$assertion_removed)"
        log WARN "CI-fix modified test assertions in: $all_tests (added=$assertion_added removed=$assertion_removed)"
    else
        CI_FIX_TEST_WARN="INFO: Structural test changes only: $all_tests"
        log INFO "CI-fix modified test files (structural only): $all_tests"
    fi
}
