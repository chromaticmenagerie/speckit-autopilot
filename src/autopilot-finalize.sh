#!/usr/bin/env bash
# autopilot-finalize.sh — run_finalize() extracted from autopilot.sh
# Handles post-merge integration check: test/lint fix loop, cross-epic review, summary.
set -euo pipefail

# ─── Auto-Revert Helper ──────────────────────────────────────────────────────

# Suggest or auto-revert a merge commit on finalize failure.
# Returns: 0=no-op (no SHA), 1=error/manual, 2=auto-reverted successfully.
_suggest_or_auto_revert() {
    local sha="$1" repo_root="$2"
    if [[ -z "$sha" ]]; then
        log WARN "No merge SHA available — cannot suggest revert"
        return 0
    fi
    if ! git -C "$repo_root" rev-parse --verify "${sha}^{commit}" &>/dev/null; then
        log ERROR "Merge SHA $sha no longer reachable — cannot auto-revert"
        return 1
    fi
    sha=$(git -C "$repo_root" rev-parse "$sha" 2>/dev/null || echo "$sha")
    local parent_count
    parent_count=$(git -C "$repo_root" rev-list --parents -1 "$sha" 2>/dev/null | wc -w)
    local merge_flag=""
    [[ "${parent_count:-0}" -ge 3 ]] && merge_flag="-m 1"
    local display_cmd="git revert --no-edit ${merge_flag} $sha && git push"

    if [[ "${AUTO_REVERT_ON_FAILURE:-false}" == "true" ]]; then
        log WARN "Auto-reverting merge $sha on ${MERGE_TARGET:-$BASE_BRANCH}"
        if git -C "$repo_root" revert --no-edit $merge_flag "$sha" && \
           git -C "$repo_root" push; then
            log OK "Merge reverted. Feature branch preserved — fix and re-merge."
            return 2
        else
            log ERROR "Auto-revert failed. Run manually: $display_cmd"
            return 1
        fi
    else
        log ERROR "To revert the last merge: $display_cmd"
        return 1
    fi
}

# ─── Error Reporting Helper ──────────────────────────────────────────────────

# Persist finalize failure data and test output for debugging/resume.
_persist_finalize_failure() {
    local repo_root="$1" reason="$2"
    local log_dir="$repo_root/.specify/logs"
    mkdir -p "$log_dir"

    # Write failure JSON
    local failure_file="$log_dir/finalize-failure.json"
    jq -nc \
        --arg reason "$reason" \
        --arg sha "${LAST_MERGE_SHA:-}" \
        --arg branch "${MERGE_TARGET:-${BASE_BRANCH:-}}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{reason:$reason, merge_sha:$sha, branch:$branch, timestamp:$ts}' \
        > "$failure_file" 2>/dev/null || true

    # Persist test output if available
    local test_out_file="$log_dir/finalize-test-output.txt"
    if [[ -n "${LAST_TEST_OUTPUT:-}" ]]; then
        printf '%s\n' "$LAST_TEST_OUTPUT" > "$test_out_file"
    fi

    log INFO "Failure data persisted to $log_dir/finalize-failure.json"
}

# Restore LAST_MERGE_SHA from status file if not already set.
_restore_merge_sha() {
    local repo_root="$1"
    if [[ -n "${LAST_MERGE_SHA:-}" ]]; then
        return 0
    fi
    local failure_file="$repo_root/.specify/logs/finalize-failure.json"
    if [[ -f "$failure_file" ]]; then
        local saved_sha
        saved_sha=$(jq -r '.merge_sha // empty' "$failure_file" 2>/dev/null || true)
        if [[ -n "$saved_sha" ]]; then
            LAST_MERGE_SHA="$saved_sha"
            log INFO "Restored LAST_MERGE_SHA=$saved_sha from finalize-failure.json"
        fi
    fi
}

# ─── Finalize (all epics merged) ─────────────────────────────────────────────

# Run finalize phase: test/lint → fix iteratively → cross-epic review → summary.
# Called when all epics are merged. Operates on base branch.
run_finalize() {
    local repo_root="$1"

    # Restore merge SHA from previous failure if resuming
    _restore_merge_sha "$repo_root"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║  FINALIZE: All Epics Merged — Integration Check        ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Ensure we're on the correct finalize branch
    local finalize_branch="${MERGE_TARGET:-$BASE_BRANCH}"
    local current_branch
    current_branch=$(git -C "$repo_root" branch --show-current)
    if [[ "$current_branch" != "$finalize_branch" ]]; then
        log INFO "Switching to $finalize_branch for finalize"
        git -C "$repo_root" checkout "$finalize_branch"
    fi

    # ── Step 1: Iterative test/lint fix loop ──
    local max_fix_rounds=3
    local round=0
    local tests_ok=false
    local build_ok=false
    local lint_ok=false

    while [[ $round -lt $max_fix_rounds ]]; do
        round=$((round + 1))
        log INFO "Finalize fix round $round/$max_fix_rounds"

        # Run tests
        if verify_tests "$repo_root"; then
            tests_ok=true
        else
            tests_ok=false
        fi

        # Run build
        if verify_build "$repo_root"; then
            build_ok=true
        else
            build_ok=false
        fi

        # Run lint
        if verify_lint "$repo_root"; then
            lint_ok=true
        else
            lint_ok=false
        fi

        # If both pass, break
        if $tests_ok && $build_ok && $lint_ok; then
            log OK "Tests, build, and lint pass on $finalize_branch"
            break
        fi

        # Invoke Claude Opus to fix failures
        log PHASE "Invoking Opus to fix test/lint failures (round $round)"

        local test_file="" lint_file=""
        if [[ -n "$LAST_TEST_OUTPUT" ]]; then
            test_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
            printf '%s' "$LAST_TEST_OUTPUT" > "$test_file"
        fi
        if [[ -n "$LAST_LINT_OUTPUT" ]]; then
            lint_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
            printf '%s' "$LAST_LINT_OUTPUT" > "$lint_file"
        fi
        local fix_prompt
        fix_prompt="$(prompt_finalize_fix "$repo_root" "$test_file" "$lint_file")"
        rm -f "$test_file" "$lint_file"

        if $DRY_RUN; then
            log INFO "[DRY RUN] Would invoke claude to fix test/lint failures"
        else
            invoke_claude "finalize-fix" "$fix_prompt" "FIN" "Fix test/lint failures" || {
                log WARN "Finalize-fix invocation failed (round $round)"
            }
        fi
    done

    if ! $tests_ok; then
        log ERROR "Finalize: tests still failing after $max_fix_rounds fix rounds"
        _persist_finalize_failure "$repo_root" "tests_failing_after_${max_fix_rounds}_rounds"
        _suggest_or_auto_revert "${LAST_MERGE_SHA:-}" "$repo_root" || true
        return 1
    fi

    if ! $lint_ok; then
        log WARN "Finalize: lint issues remain after $max_fix_rounds fix rounds (non-blocking)"
    fi

    # ── Step 2: Cross-epic integration review ──
    log PHASE "Cross-epic integration review (Opus)"

    local review_prompt
    review_prompt="$(prompt_finalize_review "$repo_root")"

    if $DRY_RUN; then
        log INFO "[DRY RUN] Would invoke claude for cross-epic integration review"
    else
        invoke_claude "finalize-review" "$review_prompt" "FIN" "Cross-epic integration review" || {
            log WARN "Finalize-review invocation failed (non-blocking)"
        }

        # Re-verify after review changes
        if ! verify_tests "$repo_root"; then
            log WARN "Tests broke during integration review — invoking fix"
            local refix_test_file="" refix_lint_file=""
            if [[ -n "$LAST_TEST_OUTPUT" ]]; then
                refix_test_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
                printf '%s' "$LAST_TEST_OUTPUT" > "$refix_test_file"
            fi
            if [[ -n "$LAST_LINT_OUTPUT" ]]; then
                refix_lint_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
                printf '%s' "$LAST_LINT_OUTPUT" > "$refix_lint_file"
            fi
            local refix_prompt
            refix_prompt="$(prompt_finalize_fix "$repo_root" "$refix_test_file" "$refix_lint_file")"
            rm -f "$refix_test_file" "$refix_lint_file"
            invoke_claude "finalize-fix" "$refix_prompt" "FIN" "Post-review fix" || true
            if ! verify_tests "$repo_root"; then
                log ERROR "Finalize: tests fail after integration review fix attempt"
                _persist_finalize_failure "$repo_root" "tests_failing_after_review_fix"
                _suggest_or_auto_revert "${LAST_MERGE_SHA:-}" "$repo_root" || true
                return 1
            fi
        fi
    fi

    # ── Step 2b: Deferred task accumulation check ──
    local total_deferred=0
    local count
    for tasks_file in "$repo_root"/specs/*/tasks.md; do
        [[ ! -f "$tasks_file" ]] && continue
        count=$(grep -c '^\- \[-\]' "$tasks_file" 2>/dev/null) || count=0
        total_deferred=$((total_deferred + count))
    done

    if [[ "$total_deferred" -gt 0 ]]; then
        log WARN "Project has $total_deferred deferred tasks across all epics — consider creating a follow-up epic"
    fi

    # ── Step 3: Generate project summary ──
    write_project_summary "$repo_root"

    log OK "Finalize complete"
    return 0
}
