#!/usr/bin/env bash
# autopilot-gates.sh — Gate functions extracted from autopilot.sh.
#
# Contains security-review and verify-ci gate loops.
# Depends on: autopilot-lib.sh (log, _emit_event), autopilot-verify.sh (verify_ci,
# _detect_test_modifications), autopilot-prompts.sh (prompt_security_review,
# prompt_security_fix, prompt_verify_ci_fix), and autopilot.sh globals
# (invoke_claude, _accumulate_phase_cost, DRY_RUN, LAST_CI_OUTPUT).

# Global side-effect: accumulated warnings across CI-fix rounds
CI_FIX_WARNINGS=""

# Severity threshold: CRITICAL | HIGH | MEDIUM | LOW — halt if findings >= this level
SECURITY_MIN_SEVERITY_TO_HALT="${SECURITY_MIN_SEVERITY_TO_HALT:-HIGH}"

# Whether CI force-skip is allowed after max rounds
CI_FORCE_SKIP_ALLOWED="${CI_FORCE_SKIP_ALLOWED:-true}"

# ─── Severity classification helper ──────────────────────────────────────

_classify_security_severity() {
    local findings_file="$1"
    local critical_count high_count medium_count low_count
    critical_count=$(grep -c '\*\*Severity\*\*: CRITICAL' "$findings_file" 2>/dev/null) || critical_count=0
    high_count=$(grep -c '\*\*Severity\*\*: HIGH' "$findings_file" 2>/dev/null) || high_count=0
    medium_count=$(grep -c '\*\*Severity\*\*: MEDIUM' "$findings_file" 2>/dev/null) || medium_count=0
    low_count=$(grep -c '\*\*Severity\*\*: LOW' "$findings_file" 2>/dev/null) || low_count=0
    echo "$critical_count $high_count $medium_count $low_count"
}

# ─── Security Gate (review→fix loop) ─────────────────────────────────────

_run_security_gate() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" epic_file="$5"
    local max_rounds=${SECURITY_MAX_ROUNDS:-3}
    local round=0
    local spec_dir="$repo_root/specs/$short_name"
    local findings_file="$spec_dir/security-findings.md"
    local tasks_file="$spec_dir/tasks.md"
    local verdict=""

    log PHASE "Security gate (max $max_rounds rounds)"

    # Resume guard: if previously halted, re-halt unless user opted in
    if [[ -f "$tasks_file" ]] && grep -q '<!-- SECURITY_FORCE_SKIPPED -->' "$tasks_file" 2>/dev/null && \
       ! grep -q '<!-- SECURITY_REVIEWED -->' "$tasks_file" 2>/dev/null; then
        if [[ "${SECURITY_FORCE_SKIP_ALLOWED:-false}" == "true" ]]; then
            log INFO "Security gate previously halted — --allow-security-skip passed, force-advancing"
            echo "" >> "$tasks_file"
            echo "<!-- SECURITY_REVIEWED -->" >> "$tasks_file"
            (cd "$repo_root" && git add "$tasks_file" && \
             git commit -m "security-review(${epic_num}): force-advanced via --allow-security-skip" 2>/dev/null || true)
            return 0
        fi
        log ERROR "Security gate previously halted — re-run with --allow-security-skip to force-advance"
        return 1
    fi

    # Initialize findings file ONCE with header (overwrite any stale file from previous run)
    cat > "$findings_file" <<SEOF
# Security Review: Epic ${epic_num}

SEOF

    while [[ $round -lt $max_rounds ]]; do
        round=$((round + 1))
        log INFO "Security review (round $round/$max_rounds)"

        # 1. Build prompt with round number and deferred-awareness injection
        local prompt
        prompt="$(prompt_security_review "$epic_num" "$title" "$repo_root" "$short_name" "$round" "$max_rounds")"
        local _sec_deferred_count
        _sec_deferred_count=$(grep -c '^\- \[-\]' "$spec_dir/tasks.md" 2>/dev/null) || _sec_deferred_count=0
        if [[ "$_sec_deferred_count" -gt 0 ]]; then
            prompt+=$'\n\n'"IMPORTANT: ${_sec_deferred_count} tasks are marked - [-] (deferred). These were NOT implemented. Check whether the omitted functionality creates security gaps (missing auth checks, missing input validation, missing rate limiting for deferred endpoints)."
        fi

        # 2. Run security-review (read-only + Write for findings file)
        invoke_claude "security-review" "$prompt" "$epic_num" "$title" || true
        _accumulate_phase_cost "$repo_root"

        # 3. Parse verdict from the LAST "Verdict:" line in findings file
        #    (file is appended per round, so last match = current round)
        if [[ ! -f "$findings_file" ]]; then
            log WARN "No findings file produced — treating as PASS"
            verdict="PASS"
            break
        fi

        verdict=$(grep -i '^Verdict:' "$findings_file" | tail -1 | awk '{print toupper($2)}')
        verdict="${verdict:-UNKNOWN}"

        if [[ "$verdict" == "PASS" ]]; then
            log OK "Security review: PASS (round $round)"
            break
        fi

        log WARN "Security review: FAIL (round $round/$max_rounds)"

        # 4. Extract ONLY the latest round's findings for the fix prompt
        #    (everything after the last "## Round" header)
        local latest_findings
        latest_findings=$(awk '/^## Round '"$round"'/{found=1} found' "$findings_file")

        # 5. Dispatch security-fix phase
        local findings_file
        findings_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
        printf '%s' "$latest_findings" > "$findings_file"
        local fix_prompt
        fix_prompt="$(prompt_security_fix "$epic_num" "$title" "$repo_root" "$short_name" "$findings_file")"
        rm -f "$findings_file"
        invoke_claude "security-fix" "$fix_prompt" "$epic_num" "$title" || {
            log WARN "Security fix invocation failed"
        }
        _accumulate_phase_cost "$repo_root"
    done

    # 6. Write marker (orchestrator responsibility — NEVER the model)
    if [[ -f "$tasks_file" ]]; then
        if [[ "$verdict" != "PASS" ]] && [[ $round -ge $max_rounds ]]; then
            if [[ "${SECURITY_FORCE_SKIP_ALLOWED:-false}" == "true" ]]; then
                # Before force-skipping, check severity
                local severities
                severities=$(_classify_security_severity "$findings_file")
                local crit high med low
                read -r crit high med low <<< "$severities"

                if [[ "$SECURITY_MIN_SEVERITY_TO_HALT" == "HIGH" ]] && (( crit + high > 0 )); then
                    log ERROR "HIGH/CRITICAL security findings ($crit critical, $high high) — halting regardless of SECURITY_FORCE_SKIP_ALLOWED"
                    return 1
                elif [[ "$SECURITY_MIN_SEVERITY_TO_HALT" == "CRITICAL" ]] && (( crit > 0 )); then
                    log ERROR "CRITICAL security findings ($crit) — halting"
                    return 1
                elif [[ "$SECURITY_MIN_SEVERITY_TO_HALT" == "LOW" ]] && (( crit + high + med + low > 0 )); then
                    log ERROR "Security findings present ($crit critical, $high high, $med medium, $low low) — halting (MIN_SEVERITY=LOW)"
                    return 1
                fi

                log WARN "Security gate: issues remain after $max_rounds rounds — force-advancing (--allow-security-skip)"
                echo "" >> "$tasks_file"
                echo "<!-- SECURITY_REVIEWED -->" >> "$tasks_file"
                if ! grep -q '<!-- SECURITY_FORCE_SKIPPED -->' "$tasks_file" 2>/dev/null; then
                    echo "<!-- SECURITY_FORCE_SKIPPED -->" >> "$tasks_file"
                fi
                (cd "$repo_root" && git add "$tasks_file" "$findings_file" && \
                 git commit -m "security-review(${epic_num}): force-advanced via --allow-security-skip after ${max_rounds} rounds" 2>/dev/null || true)
            else
                log ERROR "Security gate: unresolved findings after $max_rounds rounds — halting pipeline"
                log ERROR "Re-run with --allow-security-skip to force-advance past security failures"
                echo "" >> "$tasks_file"
                if ! grep -q '<!-- SECURITY_FORCE_SKIPPED -->' "$tasks_file" 2>/dev/null; then
                    echo "<!-- SECURITY_FORCE_SKIPPED -->" >> "$tasks_file"
                fi
                (cd "$repo_root" && git add "$tasks_file" "$findings_file" && \
                 git commit -m "security-review(${epic_num}): halted — unresolved findings after ${max_rounds} rounds" 2>/dev/null || true)
                return 1
            fi
        else
            log OK "Security gate: passed"
            echo "" >> "$tasks_file"
            echo "<!-- SECURITY_REVIEWED -->" >> "$tasks_file"
            (cd "$repo_root" && git add "$tasks_file" "$findings_file" 2>/dev/null && \
             git commit -m "security-review(${epic_num}): all checks passed" 2>/dev/null || true)
        fi
    fi

    return 0
}

# ─── Verify-CI Gate (build→fix loop) ─────────────────────────────────────

_run_verify_ci_gate() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" epic_file="$5"
    local max_rounds=3 round=0 ci_passed=false
    local tasks_file="$repo_root/specs/$short_name/tasks.md"
    local events_log="$repo_root/.specify/logs/events.jsonl"

    # Skip if already completed (resume support)
    if [[ -f "$tasks_file" ]] && grep -q '<!-- VERIFY_CI_COMPLETE -->' "$tasks_file" 2>/dev/null; then
        log INFO "verify-ci already complete — skipping"
        return 0
    fi

    # Resume guard: if previously force-skipped, auto-advance if allowed
    if grep -q '<!-- VERIFY_CI_FORCE_SKIPPED -->' "$tasks_file" 2>/dev/null; then
        if [[ "${CI_FORCE_SKIP_ALLOWED:-true}" == "true" ]]; then
            log INFO "CI gate previously force-skipped — advancing"
            grep -q '<!-- VERIFY_CI_COMPLETE -->' "$tasks_file" 2>/dev/null || \
                echo "<!-- VERIFY_CI_COMPLETE -->" >> "$tasks_file"
            return 0
        fi
    fi

    # Fast-path: no CI capabilities configured — auto-pass
    if [[ -z "${PROJECT_CI_CMD:-}" ]] && [[ -z "${PROJECT_TEST_CMD:-}" ]] && \
       [[ -z "${PROJECT_LINT_CMD:-}" ]] && [[ -z "${PROJECT_BUILD_CMD:-}" ]]; then
        log INFO "No CI capabilities configured — auto-passing verify-ci"
        echo "" >> "$tasks_file"
        echo "<!-- VERIFY_CI_COMPLETE -->" >> "$tasks_file"
        (cd "$repo_root" && git add "$tasks_file" && \
         git commit -m "chore(${epic_num}): verify-ci auto-passed (no CI configured)" 2>/dev/null || true)
        return 0
    fi

    log PHASE "Verify-CI gate (max $max_rounds rounds)"
    CI_FIX_WARNINGS=""

    while [[ $round -lt $max_rounds ]]; do
        round=$((round + 1))
        log INFO "CI verification round $round/$max_rounds"

        if verify_ci "$repo_root"; then
            ci_passed=true
            log OK "CI passed (round $round)"
            break
        fi

        log WARN "CI failed (round $round/$max_rounds)"
        [[ $round -ge $max_rounds ]] && break

        # Record HEAD before fix for test modification detection
        local head_before
        head_before=$(git -C "$repo_root" rev-parse HEAD)

        local ci_file
        ci_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
        printf '%s' "$LAST_CI_OUTPUT" > "$ci_file"
        local warn_file=""
        if [[ -n "$CI_FIX_WARNINGS" ]]; then
            warn_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
            printf '%s' "$CI_FIX_WARNINGS" > "$warn_file"
        fi
        local fix_prompt
        fix_prompt="$(prompt_verify_ci_fix "$epic_num" "$title" "$repo_root" "$ci_file" "$round" "$max_rounds" "$warn_file")"
        rm -f "$ci_file" "$warn_file"

        if $DRY_RUN; then
            log INFO "[DRY RUN] Would invoke Sonnet to fix CI failures"
        else
            invoke_claude "verify-ci-fix" "$fix_prompt" "$epic_num" "$title" || {
                log WARN "verify-ci-fix invocation failed (round $round)"
            }

            # Detect test file modifications
            _detect_test_modifications "$repo_root" "$head_before"
            if [[ -n "$CI_FIX_TEST_WARN" ]]; then
                CI_FIX_WARNINGS="${CI_FIX_WARNINGS:+$CI_FIX_WARNINGS$'\n'}Round $round: $CI_FIX_TEST_WARN"

                # Emit structured event for observability
                [[ -f "$events_log" ]] && \
                    _emit_event "$events_log" "ci_fix_test_modification" \
                        "{\"round\":$round,\"detail\":\"$CI_FIX_TEST_WARN\"}"

                # Halt on net assertion deletion — almost never a correct CI fix
                if [[ "$CI_FIX_TEST_WARN" == ERROR:* ]]; then
                    log ERROR "Net assertion deletion detected — halting CI fix loop"
                    break
                fi
            fi
        fi
        _accumulate_phase_cost "$repo_root"
    done

    # Always write marker and return 0 (like security gate pattern)
    echo "" >> "$tasks_file"
    if $ci_passed; then
        echo "<!-- VERIFY_CI_COMPLETE -->" >> "$tasks_file"
        local commit_msg="chore(${epic_num}): CI verification passed"
        [[ -n "$CI_FIX_WARNINGS" ]] && commit_msg="chore(${epic_num}): CI verification passed (test modifications detected)"
        (cd "$repo_root" && git add "$tasks_file" && \
         git commit -m "$commit_msg" 2>/dev/null || true)
    else
        if [[ "${CI_FORCE_SKIP_ALLOWED:-true}" == "true" ]]; then
            echo "<!-- VERIFY_CI_COMPLETE -->" >> "$tasks_file"
            echo "<!-- VERIFY_CI_FORCE_SKIPPED -->" >> "$tasks_file"
            log WARN "CI still failing after $max_rounds rounds — force-advancing"
            (cd "$repo_root" && git add "$tasks_file" && \
             git commit -m "chore(${epic_num}): CI verification force-skipped after $max_rounds rounds" 2>/dev/null || true)
        else
            log ERROR "CI still failing after $max_rounds rounds — halting (CI_FORCE_SKIP_ALLOWED=false)"
            return 1
        fi
    fi
    return 0
}
