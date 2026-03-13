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

# Last secret scan tier: 0=clean, 1=Tier 1 (provider, must halt), 2=Tier 2 (generic, fix loop)
LAST_SECRET_SCAN_TIER=0

# Default Tier 1 rule IDs (provider-prefixed, zero/near-zero false positives)
_DEFAULT_TIER1_RULES="aws-access-token|gcp-service-account|gcp-api-key|digitalocean-pat|cloudflare-origin-ca-key|private-key|age-secret-key|github-pat|github-fine-grained-pat|github-app-token|github-oauth|github-refresh-token|gitlab-pat|gitlab-ptt|gitlab-runner-authentication-token|stripe-access-token|slack-bot-token|slack-user-token|slack-webhook-url|openai-api-key|anthropic-api-key|anthropic-admin-api-key|sendgrid-api-token|npm-access-token|pypi-upload-token|shopify-access-token"

# Verify secrets via gitleaks. Returns 0 on pass/skip, 1 on Tier 1 finding.
# Side effect: sets LAST_SECRET_SCAN_TIER.
verify_secrets() {
    local repo_root="$1"
    LAST_SECRET_SCAN_TIER=0

    if [[ -z "${PROJECT_SECRET_SCAN_CMD:-}" ]]; then
        return 0
    fi

    log INFO "Running secret scan: gitleaks"

    local report
    report=$(mktemp "${TMPDIR:-/tmp}/autopilot-gitleaks-XXXXXX.json")

    # Determine scan scope
    local scan_mode="${PROJECT_SECRET_SCAN_MODE:-branch}"
    local changed_files=""
    if [[ "$scan_mode" == "branch" ]]; then
        changed_files=$(git -C "$repo_root" diff --name-only --diff-filter=ACMRT \
            "${MERGE_TARGET:-main}..HEAD" 2>/dev/null || true)
    fi

    # Run gitleaks from repo root with positional path argument
    local gl_rc=0
    (cd "$repo_root" && run_with_timeout 60 gitleaks dir \
        --report-format json --report-path "$report" \
        --redact --exit-code 2 --max-decode-depth=1 .) || gl_rc=$?

    # Exit code: 0=clean, 2=findings, 1=error
    if [[ $gl_rc -eq 1 ]] || [[ $gl_rc -eq 124 ]]; then
        log WARN "Gitleaks error or timeout (exit $gl_rc) — graceful skip"
        rm -f "$report"
        return 0
    fi

    if [[ ! -f "$report" ]]; then
        log WARN "Gitleaks report not generated — graceful skip"
        return 0
    fi

    if [[ $gl_rc -eq 0 ]]; then
        log OK "Secret scan clean"
        rm -f "$report"
        return 0
    fi

    # gl_rc == 2: findings found — parse and classify
    local findings
    findings=$(<"$report")
    rm -f "$report"

    # Branch-mode post-filter: only include findings in changed files
    if [[ "$scan_mode" == "branch" ]] && [[ -n "$changed_files" ]]; then
        local filtered
        filtered=$(echo "$findings" | jq --arg files "$changed_files" '
            ($files | split("\n") | map(select(. != ""))) as $cf |
            [.[] | select(.File as $f | $cf | any(. == $f))]
        ' 2>/dev/null) || filtered="$findings"
        findings="$filtered"
    fi

    # Check if any findings remain after filtering
    local finding_count
    finding_count=$(echo "$findings" | jq 'length' 2>/dev/null) || finding_count=0
    if [[ "$finding_count" -eq 0 ]]; then
        log OK "Secret scan clean (branch-filtered)"
        return 0
    fi

    # Classify findings against Tier 1 rules
    local tier1_rules="${PROJECT_SECRET_TIER1_RULES:-$_DEFAULT_TIER1_RULES}"
    local tier1_count
    tier1_count=$(echo "$findings" | jq --arg rules "$tier1_rules" '
        ($rules | split("|")) as $t1 |
        [.[] | select(.RuleID as $r | $t1 | any(. == $r))] | length
    ' 2>/dev/null) || tier1_count=0

    if [[ "$tier1_count" -gt 0 ]]; then
        LAST_SECRET_SCAN_TIER=1
        log CRITICAL "Tier 1 provider secret detected ($tier1_count finding(s)) — HALT"
        log ERROR "Rotate the secret(s) and remove from git history."
        echo "$findings" | jq -r '.[] | "  \(.RuleID): \(.File):\(.StartLine)"' 2>/dev/null || true
        return 1
    fi

    # Only Tier 2 findings
    LAST_SECRET_SCAN_TIER=2
    log WARN "Tier 2 secret findings ($finding_count) — entering fix loop"
    LAST_CI_OUTPUT="=== STEP: Secret Scan === FAIL (Tier 2 findings)"$'\n'
    LAST_CI_OUTPUT+=$(echo "$findings" | jq -r '.[] | "  \(.RuleID): \(.File):\(.StartLine) — \(.Match)"' 2>/dev/null || true)
    return 0
}

# Verify that tests pass. Returns 0 on success, 1 on failure.
# Side effect: sets LAST_TEST_OUTPUT with the captured output.
verify_tests() {
    local repo_root="$1"
    local enforcement="${2:-warn}"  # off | warn | error

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

    # Detect unconditional test stubs/skips (multi-language)
    if [[ "$enforcement" != "off" ]]; then
        # Branch-scoped skip detection: only scan files changed in this branch
        local changed_files=""
        if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            changed_files=$(git -C "$repo_root" diff --name-only --diff-filter=ACMRT \
                "${MERGE_TARGET:-main}..HEAD" 2>/dev/null || true)
        fi

        local skip_files=""
        case "${PROJECT_LANG:-unknown}" in
            Go)
                if [[ -n "$changed_files" ]]; then
                    # Filter to only branch-changed *_test.go files
                    local go_test_files
                    go_test_files=$(echo "$changed_files" | grep '_test\.go$' || true)
                    if [[ -n "$go_test_files" ]]; then
                        skip_files=$(echo "$go_test_files" | while read -r f; do
                            [[ -f "$repo_root/$f" ]] && echo "$repo_root/$f"
                        done | xargs -r awk '
/^func Test[A-Za-z0-9_]*\(/ { in_test=1; found_first=0; next }
in_test && /^}/ { in_test=0; next }
in_test && !found_first && /^\t[^\t ]/ {
    found_first=1
    if (/^\tt\.(Skip|Skipf|SkipNow)\(/) {
        print FILENAME ":" NR ": " $0
    }
}
' 2>/dev/null | grep -v '//.*speckit:allow-skip' || true)
                    fi
                else
                    skip_files=$(find "$repo_root" -name '*_test.go' \
                        -not -path '*/vendor/*' -not -path '*/.git/*' \
                        -not -path '*/node_modules/*' -not -path '*/third_party/*' \
                        -exec awk '
/^func Test[A-Za-z0-9_]*\(/ { in_test=1; found_first=0; next }
in_test && /^}/ { in_test=0; next }
in_test && !found_first && /^\t[^\t ]/ {
    found_first=1
    if (/^\tt\.(Skip|Skipf|SkipNow)\(/) {
        print FILENAME ":" NR ": " $0
    }
}
' {} + 2>/dev/null | grep -v '//.*speckit:allow-skip' || true)
                fi
                ;;
            Python)
                if [[ -n "$changed_files" ]]; then
                    local py_test_files
                    py_test_files=$(echo "$changed_files" | grep -E '(^|/)test_.*\.py$|_test\.py$' || true)
                    if [[ -n "$py_test_files" ]]; then
                        local abs_py_files
                        abs_py_files=$(echo "$py_test_files" | while read -r f; do
                            [[ -f "$repo_root/$f" ]] && echo "$repo_root/$f"
                        done)
                        if [[ -n "$abs_py_files" ]]; then
                            skip_files=$(echo "$abs_py_files" | xargs grep -nE '@pytest\.mark\.skip\b' 2>/dev/null | grep -v '#.*speckit:allow-skip' || true)
                        fi
                    fi
                else
                    skip_files=$(grep -rnE '@pytest\.mark\.skip\b' "$repo_root" \
                        --include='test_*.py' --include='*_test.py' \
                        --exclude-dir=vendor --exclude-dir=.git \
                        --exclude-dir=node_modules --exclude-dir=__pycache__ \
                        --exclude-dir=third_party 2>/dev/null | grep -v '#.*speckit:allow-skip' || true)
                fi
                ;;
            Node/JS/TS|Node-Monorepo)
                if [[ -n "$changed_files" ]]; then
                    local node_test_files
                    node_test_files=$(echo "$changed_files" | grep -E '\.(test|spec)\.(ts|js|tsx|jsx)$' || true)
                    if [[ -n "$node_test_files" ]]; then
                        local abs_node_files
                        abs_node_files=$(echo "$node_test_files" | while read -r f; do
                            [[ -f "$repo_root/$f" ]] && echo "$repo_root/$f"
                        done)
                        if [[ -n "$abs_node_files" ]]; then
                            skip_files=$(echo "$abs_node_files" | xargs grep -nE '^\s*(it|test|describe)\.skip\s*\(|^\s*x(it|describe|test)\s*\(|^\s*(it|test)\.todo\s*\(' 2>/dev/null | grep -v '//.*speckit:allow-skip' || true)
                        fi
                    fi
                else
                    skip_files=$(grep -rnE '^\s*(it|test|describe)\.skip\s*\(|^\s*x(it|describe|test)\s*\(|^\s*(it|test)\.todo\s*\(' "$repo_root" \
                        --include='*.test.ts' --include='*.test.js' --include='*.test.tsx' \
                        --include='*.test.jsx' --include='*.spec.ts' --include='*.spec.js' \
                        --exclude-dir=vendor --exclude-dir=.git \
                        --exclude-dir=node_modules --exclude-dir=dist \
                        --exclude-dir=third_party 2>/dev/null | grep -v '//.*speckit:allow-skip' || true)
                fi
                ;;
            Rust)
                if [[ -n "$changed_files" ]]; then
                    local rust_files
                    rust_files=$(echo "$changed_files" | grep '\.rs$' || true)
                    if [[ -n "$rust_files" ]]; then
                        local abs_rust_files
                        abs_rust_files=$(echo "$rust_files" | while read -r f; do
                            [[ -f "$repo_root/$f" ]] && echo "$repo_root/$f"
                        done)
                        if [[ -n "$abs_rust_files" ]]; then
                            skip_files=$(echo "$abs_rust_files" | xargs grep -nE '#\[ignore\]' 2>/dev/null | grep -v '//.*speckit:allow-skip' || true)
                        fi
                    fi
                else
                    skip_files=$(grep -rnE '#\[ignore\]' "$repo_root" \
                        --include='*.rs' \
                        --exclude-dir=vendor --exclude-dir=.git \
                        --exclude-dir=target --exclude-dir=third_party 2>/dev/null | grep -v '//.*speckit:allow-skip' || true)
                fi
                ;;
            *)
                # Unknown/Makefile — skip stub detection (no reliable pattern)
                skip_files=""
                ;;
        esac
        if [[ -n "$skip_files" ]]; then
            local skip_count
            skip_count=$(echo "$skip_files" | wc -l | tr -d ' ')
            if [[ "$enforcement" == "error" ]]; then
                log ERROR "Found $skip_count skip marker(s) with skip/stub markers:"
                echo "$skip_files" | while read -r f; do
                    log ERROR "  - $f"
                done
                return 1
            else
                # enforcement == warn
                log WARN "Found $skip_count skip marker(s) with skip/stub markers (enforcement=warn):"
                echo "$skip_files" | while read -r f; do
                    log WARN "  - $f"
                done
            fi
        fi
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

    # Step 0: Secret scanning (before any other checks — Path B only)
    if [[ -n "${PROJECT_SECRET_SCAN_CMD:-}" ]]; then
        if ! verify_secrets "$repo_root"; then
            if [[ "${LAST_SECRET_SCAN_TIER:-0}" -eq 1 ]]; then
                LAST_CI_OUTPUT="=== STEP: Secret Scan === HALT (Tier 1 provider secret detected)"
            fi
            rm -f "$tmpfile"; return 1
        fi
    fi


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
    if ! verify_tests "$repo_root" "$STUB_ENFORCEMENT_LEVEL"; then
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
