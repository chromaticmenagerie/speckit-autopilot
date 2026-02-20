#!/usr/bin/env bash
# autopilot-finalize.sh — run_finalize() extracted from autopilot.sh
# Handles post-merge integration check: test/lint fix loop, cross-epic review, summary.
set -euo pipefail

# ─── Finalize (all epics merged) ─────────────────────────────────────────────

# Run finalize phase: test/lint → fix iteratively → cross-epic review → summary.
# Called when all epics are merged. Operates on base branch.
run_finalize() {
    local repo_root="$1"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║  FINALIZE: All Epics Merged — Integration Check        ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Ensure we're on base branch
    local current_branch
    current_branch=$(git -C "$repo_root" branch --show-current)
    if [[ "$current_branch" != "$BASE_BRANCH" ]]; then
        log INFO "Switching to $BASE_BRANCH for finalize"
        git -C "$repo_root" checkout "$BASE_BRANCH"
    fi

    # ── Step 1: Iterative test/lint fix loop ──
    local max_fix_rounds=3
    local round=0
    local tests_ok=false
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

        # Run lint
        if verify_lint "$repo_root"; then
            lint_ok=true
        else
            lint_ok=false
        fi

        # If both pass, break
        if $tests_ok && $lint_ok; then
            log OK "Tests and lint pass on $BASE_BRANCH"
            break
        fi

        # Invoke Claude Opus to fix failures
        log PHASE "Invoking Opus to fix test/lint failures (round $round)"

        local fix_prompt
        fix_prompt="$(prompt_finalize_fix "$repo_root" "$LAST_TEST_OUTPUT" "$LAST_LINT_OUTPUT")"

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
            local refix_prompt
            refix_prompt="$(prompt_finalize_fix "$repo_root" "$LAST_TEST_OUTPUT" "$LAST_LINT_OUTPUT")"
            invoke_claude "finalize-fix" "$refix_prompt" "FIN" "Post-review fix" || true
            if ! verify_tests "$repo_root"; then
                log ERROR "Finalize: tests fail after integration review fix attempt"
                return 1
            fi
        fi
    fi

    # ── Step 3: Generate project summary ──
    write_project_summary "$repo_root"

    log OK "Finalize complete"
    return 0
}
