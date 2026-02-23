#!/usr/bin/env bash
# autopilot-coderabbit.sh — CodeRabbit integration + remote merge pipeline
#
# Handles: CLI review, PR creation, PR review polling, conflict resolution,
# remote merge via gh, and local merge fallback.
#
# Sourced by autopilot.sh. Requires: autopilot-lib.sh (log, mark_epic_merged,
# verify_tests), autopilot-prompts.sh (prompt_coderabbit_fix, prompt_conflict_resolve),
# autopilot-stream.sh (_emit_event).

set -euo pipefail

SCRIPT_DIR_CR="${SCRIPT_DIR:-$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Globals set during remote merge, read by write_epic_summary()
LAST_PR_NUMBER=""
LAST_CR_STATUS=""

# do_merge() (local fallback) remains in autopilot.sh

# ─── Remote Merge Orchestrator ──────────────────────────────────────────────

# Full remote merge pipeline: CLI review → rebase → push → PR → CR review → merge.
# Falls back to do_merge() if no remote or no gh CLI.
do_remote_merge() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" epic_file="${5:-}"
    local events_log="$repo_root/.specify/logs/events.jsonl"

    # Gate: no remote → local merge
    if [[ "${HAS_REMOTE:-false}" != "true" ]]; then
        log INFO "No git remote — falling back to local merge"
        do_merge "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"
        return $?
    fi

    # Gate: no gh CLI → local merge
    if [[ "${HAS_GH_CLI:-false}" != "true" ]]; then
        log WARN "gh CLI not installed — falling back to local merge"
        do_merge "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"
        return $?
    fi

    # Interactive confirmation
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Epic $epic_num: $title — READY TO PUSH & CREATE PR${RESET}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo ""

    local files_changed
    files_changed=$(git -C "$repo_root" diff --name-only "$MERGE_TARGET"..HEAD | wc -l)
    echo -e "  Files changed: ${BOLD}$files_changed${RESET}"
    echo -e "  Target: ${BOLD}origin/$MERGE_TARGET${RESET}"
    echo ""

    if [[ -t 0 ]]; then
        echo -n "Push $short_name & create PR to $MERGE_TARGET? [Y/n] "
        read -r confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            log WARN "Remote merge declined — falling back to local merge"
            do_merge "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"
            return $?
        fi
    else
        log INFO "Non-interactive mode — auto-proceeding with remote merge"
    fi

    _emit_event "$events_log" "remote_merge_start" \
        "$(jq -nc --arg e "$epic_num" '{epic:$e}')"

    # Step 1: CodeRabbit CLI review (optional)
    if [[ "${HAS_CODERABBIT:-false}" == "true" ]]; then
        local _cli_rc=0
        _coderabbit_cli_review "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file" "$events_log" || _cli_rc=$?
        if [[ $_cli_rc -eq 2 ]]; then
            log WARN "CodeRabbit CLI stalled — continuing to push/PR"
        elif [[ $_cli_rc -ne 0 ]]; then
            return 1
        fi
    fi

    # Step 2: Commit dirty tree before push
    if ! git -C "$repo_root" diff --quiet 2>/dev/null || \
       ! git -C "$repo_root" diff --cached --quiet 2>/dev/null; then
        log WARN "Uncommitted changes — committing before push"
        git -C "$repo_root" add -A
        git -C "$repo_root" commit -m "chore(${epic_num}): commit remaining changes before push"
    fi

    # Step 3: Rebase and push
    if ! _rebase_and_push "$repo_root" "$epic_num" "$short_name" "$title" "$events_log"; then
        log ERROR "Rebase/push failed — stopping. Resolve and re-run: ./autopilot.sh $epic_num"
        return 1
    fi

    # Step 4: Create PR
    local pr_num
    pr_num=$(_create_or_find_pr "$repo_root" "$epic_num" "$short_name" "$title" "$events_log") || {
        log ERROR "PR creation failed"
        return 1
    }
    LAST_PR_NUMBER="$pr_num"

    # Step 5: CodeRabbit PR review (optional)
    if [[ "${HAS_CODERABBIT:-false}" == "true" ]]; then
        local _pr_rc=0
        _poll_coderabbit_pr "$repo_root" "$epic_num" "$short_name" "$title" "$pr_num" "$events_log" || _pr_rc=$?
        if [[ $_pr_rc -eq 2 ]]; then
            LAST_CR_STATUS="stalled"
        elif [[ $_pr_rc -ne 0 ]]; then
            return 1
        else
            LAST_CR_STATUS="reviewed"
        fi
    else
        LAST_CR_STATUS="skipped"
    fi

    # Step 6: Merge PR
    if ! _check_and_merge_pr "$repo_root" "$epic_num" "$short_name" "$title" "$pr_num" "$events_log"; then
        log ERROR "PR merge failed"
        return 1
    fi

    # Step 7: Post-merge cleanup
    _post_merge_cleanup "$repo_root" "$epic_num" "$short_name" "$epic_file"

    _emit_event "$events_log" "remote_merge_complete" \
        "$(jq -nc --arg e "$epic_num" --argjson pr "$pr_num" '{epic:$e, pr:$pr}')"

    return 0
}

# ─── CodeRabbit CLI Review ──────────────────────────────────────────────────

# Convergence loop: run CLI → parse → Claude fix → retry (max 3).
# Non-blocking: always returns 0 (force-advances on failure/rate-limit).
_coderabbit_cli_review() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" epic_file="$5" events_log="$6"
    local max_retries=3 attempt=0
    local -a _cli_issue_counts=()

    log PHASE "CodeRabbit CLI review"

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        log INFO "CodeRabbit CLI review (round $attempt/$max_retries)"

        local tmpfile rc=0
        tmpfile=$(mktemp)
        (cd "$repo_root" && coderabbit review --prompt-only --base "$MERGE_TARGET") \
            > "$tmpfile" 2>&1 || rc=$?

        # Rate limit / network error → skip
        if [[ $rc -ne 0 ]]; then
            local output
            output=$(<"$tmpfile"); rm -f "$tmpfile"
            if echo "$output" | grep -qi "rate.limit\|429\|too many requests"; then
                log WARN "CodeRabbit rate limited — skipping CLI review"
                return 0
            fi
            log WARN "CodeRabbit CLI error (exit $rc) — skipping"
            return 0
        fi

        local review_output
        review_output=$(<"$tmpfile"); rm -f "$tmpfile"

        # Check if review is clean
        if _cr_cli_is_clean "$review_output"; then
            log OK "CodeRabbit CLI review: clean"
            _emit_event "$events_log" "coderabbit_cli_clean" \
                "$(jq -nc --arg e "$epic_num" '{epic:$e}')"
            return 0
        fi

        log WARN "CodeRabbit CLI found issues (round $attempt/$max_retries)"
        local _cli_issue_count
        _cli_issue_count=$(_count_cli_issues "$review_output")
        _cli_issue_counts+=("$_cli_issue_count")
        if _check_stall "${_cli_issue_counts[*]}" "${CONVERGENCE_STALL_ROUNDS:-2}"; then
            log WARN "CodeRabbit CLI stalled — same issue count for ${CONVERGENCE_STALL_ROUNDS:-2} rounds"
            _emit_event "$events_log" "coderabbit_cli_stalled" \
                "$(jq -nc --arg e "$epic_num" --argjson ic "$_cli_issue_count" '{epic:$e, issue_count:$ic}')"
            return 2
        fi
        _emit_event "$events_log" "coderabbit_cli_issues" \
            "$(jq -nc --arg e "$epic_num" --argjson a "$attempt" --argjson ic "$_cli_issue_count" '{epic:$e, attempt:$a, issue_count:$ic}')"

        # Claude fix
        local fix_prompt
        fix_prompt="$(prompt_coderabbit_fix "$epic_num" "$title" "$repo_root" "$short_name" "$review_output")"
        invoke_claude "coderabbit-fix" "$fix_prompt" "$epic_num" "$title" || {
            log WARN "Claude fix invocation failed"
        }
    done

    if [[ "${FORCE_ADVANCE_ON_REVIEW_FAIL:-false}" == "true" ]]; then
        log WARN "CodeRabbit CLI: issues remain after $max_retries rounds — force-advancing"
        return 0
    fi
    log ERROR "CodeRabbit CLI: issues remain after $max_retries rounds — halting"
    log ERROR "Set FORCE_ADVANCE_ON_REVIEW_FAIL=true in .specify/project.env to skip"
    return 1
}

# ─── Rebase & Push ──────────────────────────────────────────────────────────

# Fetch → rebase → conflict resolution (max 3) → test → push.
_rebase_and_push() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" events_log="$5"
    local max_retries=3 attempt=0

    git -C "$repo_root" fetch origin "$MERGE_TARGET" || {
        log ERROR "Failed to fetch origin/$MERGE_TARGET"
        return 1
    }

    # Skip rebase if branch already includes base — avoids unnecessary rebase+push
    if git -C "$repo_root" merge-base --is-ancestor "origin/$MERGE_TARGET" HEAD 2>/dev/null; then
        log OK "Branch already up-to-date with origin/$MERGE_TARGET — skipping rebase"
        # Still push in case local commits haven't been pushed yet
        log INFO "Pushing $short_name to origin"
        local push_output
        push_output=$(git -C "$repo_root" push -u origin "$short_name" --force-with-lease 2>&1) || {
            log ERROR "Push failed: ${push_output:0:500}"
            return 1
        }
        log OK "Pushed $short_name to origin"
        return 0
    fi

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))

        local rc=0 rebase_output
        rebase_output=$(git -C "$repo_root" rebase "origin/$MERGE_TARGET" 2>&1) || rc=$?

        if [[ $rc -eq 0 ]]; then
            log OK "Rebase clean"
            break
        fi

        # Distinguish rebase failure types
        if echo "$rebase_output" | grep -qi "is up to date"; then
            log OK "Branch already up-to-date — nothing to rebase"
            break
        fi

        if echo "$rebase_output" | grep -qi "cannot rebase\|unstaged changes\|staged changes"; then
            git -C "$repo_root" rebase --abort 2>/dev/null || true
            log ERROR "Rebase failed — dirty working tree: ${rebase_output:0:500}"
            return 1
        fi

        log WARN "Rebase failed (attempt $attempt/$max_retries): ${rebase_output:0:300}"
        _emit_event "$events_log" "rebase_conflict" \
            "$(jq -nc --arg e "$epic_num" --argjson a "$attempt" '{epic:$e, attempt:$a}')"

        local conflict_files
        conflict_files=$(git -C "$repo_root" diff --name-only --diff-filter=U 2>/dev/null || echo "")

        if [[ -z "$conflict_files" ]]; then
            git -C "$repo_root" rebase --abort 2>/dev/null || true
            log ERROR "Rebase failed (no conflict markers): ${rebase_output:0:500}"
            return 1
        fi

        # Claude resolves conflicts
        local resolve_prompt
        resolve_prompt="$(prompt_conflict_resolve "$epic_num" "$title" "$repo_root" "$conflict_files")"
        invoke_claude "conflict-resolve" "$resolve_prompt" "$epic_num" "$title" || {
            git -C "$repo_root" rebase --abort 2>/dev/null || true
            log ERROR "Claude conflict resolution failed"
            if [[ $attempt -ge $max_retries ]]; then return 1; fi
            continue
        }

        # Continue rebase after resolution
        git -C "$repo_root" rebase --continue 2>/dev/null || {
            git -C "$repo_root" rebase --abort 2>/dev/null || true
            if [[ $attempt -ge $max_retries ]]; then return 1; fi
        }
    done

    if [[ $attempt -ge $max_retries ]]; then
        log ERROR "Rebase failed after $max_retries attempts — stopping"
        log ERROR "Resolve conflicts manually, then: ./autopilot.sh $epic_num"
        return 1
    fi

    # Verify tests pass after rebase
    if [[ -n "${PROJECT_TEST_CMD:-}" ]]; then
        if ! verify_tests "$repo_root"; then
            log WARN "Tests fail after rebase — invoking fix"
            local fix_prompt
            fix_prompt="$(prompt_finalize_fix "$repo_root" "$LAST_TEST_OUTPUT" "")"
            invoke_claude "coderabbit-fix" "$fix_prompt" "$epic_num" "$title" || true
            if ! verify_tests "$repo_root"; then
                log ERROR "Tests still failing after rebase — stopping"
                return 1
            fi
        fi
    fi

    # Push
    log INFO "Pushing $short_name to origin"
    local push_output
    push_output=$(git -C "$repo_root" push -u origin "$short_name" --force-with-lease 2>&1) || {
        log ERROR "Push failed: ${push_output:0:500}"
        return 1
    }
    log OK "Pushed $short_name to origin"
    return 0
}

# ─── PR Creation ────────────────────────────────────────────────────────────

# Create a GitHub PR or find existing one. Echoes PR number on success.
_create_or_find_pr() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" events_log="$5"

    # Check for existing PR
    local existing_pr
    existing_pr=$(cd "$repo_root" && gh pr list --head "$short_name" --base "$MERGE_TARGET" \
        --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -n "$existing_pr" ]] && [[ "$existing_pr" != "null" ]]; then
        log INFO "Existing PR #$existing_pr found"
        echo "$existing_pr"
        return 0
    fi

    # Create new PR
    local pr_url
    pr_url=$(cd "$repo_root" && gh pr create \
        --base "$MERGE_TARGET" \
        --head "$short_name" \
        --title "Epic $epic_num: $title" \
        --body "Auto-generated by autopilot for epic $epic_num.") || {
        log ERROR "PR creation failed"
        return 1
    }

    # Extract PR number from URL
    local pr_num
    pr_num=$(echo "$pr_url" | grep -oE '[0-9]+$')

    if [[ -z "$pr_num" ]]; then
        log ERROR "Could not extract PR number from: $pr_url"
        return 1
    fi

    log OK "Created PR #$pr_num ($pr_url)"
    _emit_event "$events_log" "pr_created" \
        "$(jq -nc --arg e "$epic_num" --argjson pr "$pr_num" '{epic:$e, pr:$pr}')"
    echo "$pr_num"
    return 0
}

# ─── CodeRabbit PR Review Polling ───────────────────────────────────────────

# Poll for coderabbitai[bot] review. Fix loop on CHANGES_REQUESTED (max 3).
# Non-blocking: force-advances on timeout or max retries.
_poll_coderabbit_pr() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" pr_num="$5" events_log="$6"
    local max_retries=3 attempt=0
    local poll_interval=30
    local poll_timeout=600
    local -a _pr_issue_counts=()

    log PHASE "Waiting for CodeRabbit PR review on #$pr_num"

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        log INFO "CodeRabbit PR review poll (round $attempt/$max_retries)"

        local review_state="" waited=0

        while [[ $waited -lt $poll_timeout ]]; do
            review_state=$(_cr_pr_review_state "$repo_root" "$pr_num")

            if [[ "$review_state" == "APPROVED" ]]; then
                log OK "CodeRabbit PR review: APPROVED"
                _emit_event "$events_log" "coderabbit_pr_approved" \
                    "$(jq -nc --arg e "$epic_num" --argjson pr "$pr_num" '{epic:$e, pr:$pr}')"
                return 0
            fi

            if [[ "$review_state" == "CHANGES_REQUESTED" ]]; then
                break
            fi

            # Still pending
            sleep "$poll_interval"
            waited=$((waited + poll_interval))
        done

        # Timeout → force-advance
        if [[ "$review_state" != "CHANGES_REQUESTED" ]]; then
            log WARN "CodeRabbit PR review timed out after ${poll_timeout}s — force-advancing (PR #${pr_num} may need manual review)"
            return 2
        fi

        log WARN "CodeRabbit PR: CHANGES_REQUESTED (round $attempt/$max_retries)"

        # Get comments and fix
        local comments
        comments=$(_cr_pr_comments "$repo_root" "$pr_num")
        local _pr_issue_count
        _pr_issue_count=$(_count_pr_issues "$comments")
        _pr_issue_counts+=("$_pr_issue_count")
        if _check_stall "${_pr_issue_counts[*]}" "${CONVERGENCE_STALL_ROUNDS:-2}"; then
            log WARN "CodeRabbit PR stalled — same issue count for ${CONVERGENCE_STALL_ROUNDS:-2} rounds"
            _emit_event "$events_log" "coderabbit_pr_stalled" \
                "$(jq -nc --arg e "$epic_num" --argjson pr "$pr_num" --argjson ic "$_pr_issue_count" '{epic:$e, pr:$pr, issue_count:$ic}')"
            return 2
        fi
        _emit_event "$events_log" "coderabbit_pr_changes_requested" \
            "$(jq -nc --arg e "$epic_num" --argjson pr "$pr_num" --argjson a "$attempt" --argjson ic "$_pr_issue_count" \
            '{epic:$e, pr:$pr, attempt:$a, issue_count:$ic}')"

        local fix_prompt
        fix_prompt="$(prompt_coderabbit_fix "$epic_num" "$title" "$repo_root" "$short_name" "$comments")"
        invoke_claude "coderabbit-fix" "$fix_prompt" "$epic_num" "$title" || {
            log WARN "Claude fix invocation failed"
        }

        # Push fixes
        git -C "$repo_root" push origin "$short_name" --force-with-lease || {
            log ERROR "Push failed after PR review fix"
            return 1
        }

        # Let CodeRabbit pick up the new push
        sleep 10
    done

    log WARN "CodeRabbit PR: issues remain after $max_retries rounds — force-advancing (PR #${pr_num} may need manual review)"
    return 2
}

# ─── Mergeable Check & Merge ───────────────────────────────────────────────

# Verify PR is mergeable, then merge via gh. Retry on conflicts.
_check_and_merge_pr() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" pr_num="$5" events_log="$6"
    local max_retries=3 attempt=0

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))

        local mergeable
        mergeable=$(cd "$repo_root" && gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")

        # Poll for UNKNOWN state — GitHub may still be computing mergeability
        if [[ "$mergeable" == "UNKNOWN" ]]; then
            local poll_wait=2 poll_total=0 poll_max=30
            log INFO "PR #$pr_num mergeable state UNKNOWN — polling (max ${poll_max}s)"
            while [[ $poll_total -lt $poll_max ]]; do
                sleep "$poll_wait"
                poll_total=$((poll_total + poll_wait))
                mergeable=$(cd "$repo_root" && gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null || echo "UNKNOWN")
                if [[ "$mergeable" != "UNKNOWN" ]]; then
                    log INFO "PR #$pr_num mergeable state resolved: $mergeable (after ${poll_total}s)"
                    break
                fi
                poll_wait=$((poll_wait * 2))
                if (( poll_wait > 16 )); then poll_wait=16; fi
            done
        fi

        if [[ "$mergeable" == "MERGEABLE" ]]; then
            cd "$repo_root" && gh pr merge "$pr_num" --merge \
                --subject "merge: $short_name — $title" || {
                log ERROR "gh pr merge failed"
                return 1
            }
            log OK "PR #$pr_num merged"
            _emit_event "$events_log" "pr_merged" \
                "$(jq -nc --arg e "$epic_num" --argjson pr "$pr_num" '{epic:$e, pr:$pr}')"
            return 0
        fi

        # CONFLICTING or still UNKNOWN after polling — rebase needed
        log WARN "PR not mergeable ($mergeable) — rebasing (attempt $attempt/$max_retries)"

        if ! _rebase_and_push "$repo_root" "$epic_num" "$short_name" "$title" "$events_log"; then
            return 1
        fi

        sleep 5
    done

    log ERROR "PR not mergeable after $max_retries attempts — stopping"
    return 1
}

# ─── Post-Merge Cleanup ────────────────────────────────────────────────────

# Mark merged FIRST (durable state), then checkout base as non-fatal cleanup.
_post_merge_cleanup() {
    local repo_root="$1" epic_num="$2" short_name="$3" epic_file="${4:-}"

    # Mark epic as merged FIRST (durable state before cleanup)
    if [[ -n "$epic_file" ]] && [[ -f "$epic_file" ]]; then
        mark_epic_merged "$epic_file" "$short_name"
        git -C "$repo_root" add "$epic_file"
        git -C "$repo_root" commit -m "fix($epic_num): mark epic YAML as merged" || true
        git -C "$repo_root" push origin HEAD || log WARN "Failed to push YAML marker"
    fi

    # Cleanup: switch to base branch (non-fatal — state is already durable)
    git -C "$repo_root" checkout "$MERGE_TARGET" || {
        log WARN "Failed to checkout $MERGE_TARGET after merge — manual cleanup needed"
        return 0
    }
    git -C "$repo_root" pull origin "$MERGE_TARGET" || {
        log WARN "git pull failed — continuing"
    }

    return 0
}

# ─── Internal Helpers ───────────────────────────────────────────────────────

source "${SCRIPT_DIR}/autopilot-coderabbit-helpers.sh"
