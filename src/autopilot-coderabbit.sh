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

    # Suppress ANSI color from gh CLI output
    export GH_NO_COLOR=1

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

    if [[ "${AUTOPILOT_NO_CONFIRM:-false}" == "true" ]]; then
        log INFO "AUTOPILOT_NO_CONFIRM set — auto-proceeding with remote merge"
    elif [[ -t 0 ]]; then
        echo -n "Push $short_name & create PR to $MERGE_TARGET? [Y/n] (auto-yes in 10s) "
        local confirm=""
        read -r -t 10 confirm || {
            confirm="Y"
            log INFO "Prompt timed out after 10s — auto-proceeding with Y"
        }
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


    # Ensure CodeRabbit config exists with sensible defaults
    ensure_coderabbit_config "$repo_root"

    # Step 1: CodeRabbit CLI review (optional)
    if [[ "${HAS_CODERABBIT:-false}" == "true" ]] && [[ "${SKIP_CODERABBIT:-false}" != "true" ]]; then
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

    # Step 5: CodeRabbit PR review — removed in v0.6.0
    [[ -z "$LAST_CR_STATUS" ]] && LAST_CR_STATUS="skipped"  # preserve CLI review status if set

    # Step 6: Merge PR
    if ! _check_and_merge_pr "$repo_root" "$epic_num" "$short_name" "$title" "$pr_num" "$events_log"; then
        log ERROR "PR merge failed"
        return 1
    fi

    # Step 6b: Sync GitHub Projects (close task/epic issues)
    gh_sync_done "$repo_root" "$epic_num" "$repo_root/specs/$short_name/tasks.md" || \
        log WARN "GitHub sync-done failed — continuing with cleanup"

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
    local max_retries=${CODERABBIT_MAX_ROUNDS:-3} attempt=0
    local -a _cli_issue_counts=()

    log PHASE "CodeRabbit CLI review"

    # Pre-flight: verify CodeRabbit auth
    if ! coderabbit auth status >/dev/null 2>&1; then
        log WARN "CodeRabbit CLI not authenticated — skipping review"
        LAST_CR_STATUS="skipped (not authenticated)"
        return 0
    fi

    while [[ $attempt -lt $max_retries ]]; do
        attempt=$((attempt + 1))
        log INFO "CodeRabbit CLI review (round $attempt/$max_retries)"

        local tmpfile rc=0 _cr_retry=0 _cr_max_retries=3
        local -a _backoff_secs=(10 30 60)
        while [[ $_cr_retry -lt $_cr_max_retries ]]; do
            tmpfile=$(mktemp)
            rc=0
            (cd "$repo_root" && coderabbit review --prompt-only --base "$MERGE_TARGET" < /dev/null) \
                > "$tmpfile" 2>&1 || rc=$?

            if [[ $rc -eq 0 ]]; then
                break
            fi

            _cr_retry=$((_cr_retry + 1))
            if [[ $_cr_retry -lt $_cr_max_retries ]]; then
                local _cr_output
                _cr_output=$(<"$tmpfile"); rm -f "$tmpfile"

                local _err_type
                _err_type=$(_classify_cr_error "$_cr_output")

                case "$_err_type" in
                    rate_limit)
                        log WARN "CodeRabbit rate limited — skipping CLI review"
                        LAST_CR_STATUS="skipped (rate limited)"
                        return 0
                        ;;
                    auth_error)
                        log WARN "CodeRabbit auth error — skipping CLI review (run: coderabbit auth login)"
                        LAST_CR_STATUS="skipped (auth error — run: coderabbit auth login)"
                        return 0
                        ;;
                    service_error)
                        local _wait=${_backoff_secs[$_cr_retry - 1]:-60}
                        log WARN "CodeRabbit service error (exit $rc) — retrying in ${_wait}s (attempt $_cr_retry/$_cr_max_retries)"
                        sleep "$_wait"
                        ;;
                    *)
                        log WARN "CodeRabbit CLI error (exit $rc) — retrying in 10s (attempt $_cr_retry/$_cr_max_retries)"
                        sleep 10
                        ;;
                esac
            fi
        done

        # Final error handling after retries exhausted
        if [[ $rc -ne 0 ]]; then
            local output
            output=$(<"$tmpfile"); rm -f "$tmpfile"

            # Persist error to diagnostic log
            local error_log="$repo_root/.specify/logs/${epic_num}-coderabbit-errors.log"
            mkdir -p "$repo_root/.specify/logs"
            {
                echo "--- $(date -u '+%Y-%m-%dT%H:%M:%SZ') | round $attempt | exit $rc | retries $_cr_retry ---"
                echo "$output" | head -20
                echo ""
            } >> "$error_log"

            # Emit structured event with error classification
            local _err_snippet _err_type
            _err_snippet=$(echo "$output" | head -5 | tr '\n' ' ' | cut -c1-300)
            _err_type=$(_classify_cr_error "$output")
            _emit_event "$events_log" "coderabbit_cli_error" \
                "$(jq -nc --arg e "$epic_num" --argjson rc "$rc" --arg err "$_err_snippet" \
                    --argjson retry "$_cr_retry" --arg etype "$_err_type" \
                    '{epic:$e, exit_code:$rc, error_snippet:$err, retry_count:$retry, error_type:$etype}')"

            case "$_err_type" in
                rate_limit)   LAST_CR_STATUS="skipped (rate limited)" ;;
                service_error) LAST_CR_STATUS="skipped (service error after $_cr_retry retries)" ;;
                auth_error)   LAST_CR_STATUS="skipped (auth error — run: coderabbit auth login)" ;;
                *)            LAST_CR_STATUS="skipped (CLI error: exit $rc)" ;;
            esac
            log WARN "CodeRabbit CLI: $LAST_CR_STATUS"
            return 0
        fi

        local review_output
        review_output=$(<"$tmpfile")

        # Persist findings to a durable log file before cleaning up the temp file
        local findings_log_dir="$repo_root/.specify/logs"
        local findings_log="$findings_log_dir/${epic_num}-coderabbit-findings.md"
        mkdir -p "$findings_log_dir"
        {
            echo ""
            echo "## Round $attempt / $max_retries"
            echo "_Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')_"
            echo ""
            echo "$review_output"
        } >> "$findings_log"

        rm -f "$tmpfile"

        # Check if review is clean
        if _cr_cli_is_clean "$review_output"; then
            log OK "CodeRabbit CLI review: clean"
            _emit_event "$events_log" "coderabbit_cli_clean" \
                "$(jq -nc --arg e "$epic_num" '{epic:$e}')"
            LAST_CR_STATUS="clean"
            return 0
        fi

        log WARN "CodeRabbit CLI found issues (round $attempt/$max_retries)"
        local _cli_issue_count
        _cli_issue_count=$(_count_cli_issues "$review_output")
        _cli_issue_count="${_cli_issue_count:-0}"
        [[ "$_cli_issue_count" =~ ^[0-9]+$ ]] || _cli_issue_count=0
        _cli_issue_counts+=("$_cli_issue_count")
        if _check_stall "${_cli_issue_counts[*]}" "${CONVERGENCE_STALL_ROUNDS:-2}"; then
            log WARN "CodeRabbit CLI stalled — same issue count for ${CONVERGENCE_STALL_ROUNDS:-2} rounds"
            _emit_event "$events_log" "coderabbit_cli_stalled" \
                "$(jq -nc --arg e "$epic_num" --argjson ic "$_cli_issue_count" '{epic:$e, issue_count:$ic}')"
            if [[ "${FORCE_ADVANCE_ON_REVIEW_STALL:-false}" == "true" ]]; then
                log WARN "FORCE_ADVANCE_ON_REVIEW_STALL set — force-advancing after $attempt rounds (stall detected)"
                LAST_CR_STATUS="force-advanced (stall after $attempt rounds)"
                return 0
            fi
            return 2
        fi

        # Early exit when force-advance is enabled and we've completed enough rounds
        if [[ "${FORCE_ADVANCE_ON_REVIEW_STALL:-false}" == "true" ]] && [[ $attempt -ge 2 ]]; then
            log WARN "FORCE_ADVANCE_ON_REVIEW_STALL set — force-advancing after $attempt rounds (diminishing returns)"
            LAST_CR_STATUS="force-advanced (diminishing returns after $attempt rounds)"
            return 0
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

    if [[ "${FORCE_ADVANCE_ON_REVIEW_ERROR:-false}" == "true" ]]; then
        log WARN "CodeRabbit CLI: issues remain after $max_retries rounds — force-advancing"
        LAST_CR_STATUS="force-advanced (issues remain after $max_retries rounds)"
        return 0
    fi
    log ERROR "CodeRabbit CLI: issues remain after $max_retries rounds — halting"
    log ERROR "Set FORCE_ADVANCE_ON_REVIEW_ERROR=true in .specify/project.env to skip"
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

    # Verify build passes after rebase
    if [[ -n "${PROJECT_BUILD_CMD:-}" ]]; then
        if ! verify_build "$repo_root"; then
            log ERROR "Build failed — aborting merge"
            log ERROR "Output: $LAST_BUILD_OUTPUT"
            return 1
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

# ─── PR Body Helper ──────────────────────────────────────────────────────────

_pr_body() {
    local repo_root="$1" epic_num="$2" title="$3" short_name="$4"
    cat <<PRBODY
## Epic $epic_num: $title

### Changes
$(git -C "$repo_root" diff --stat "$MERGE_TARGET"..HEAD 2>/dev/null | tail -20 || echo "No diff available")

### Tasks Completed
$(grep -ci '\[x\]' "$repo_root/specs/$short_name/tasks.md" 2>/dev/null || echo "unknown") tasks completed

### Test Status
$(if [[ -n "${PROJECT_TEST_CMD:-}" ]]; then echo "Tests verified before push."; else echo "No test command configured."; fi)
PRBODY
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
        log INFO "Existing PR #$existing_pr found — updating body"
        gh pr edit "$existing_pr" --body "$(_pr_body "$repo_root" "$epic_num" "$title" "$short_name")" >/dev/null 2>&1 || true
        echo "$existing_pr"
        return 0
    fi

    # Create new PR
    local pr_url
    pr_url=$(cd "$repo_root" && gh pr create \
        --base "$MERGE_TARGET" \
        --head "$short_name" \
        --title "Epic $epic_num: $title" \
        --body "$(_pr_body "$repo_root" "$epic_num" "$title" "$short_name")") || {
        log ERROR "PR creation failed"
        return 1
    }
    pr_url=$(echo "$pr_url" | sed 's/\x1b\[[0-9;]*m//g')

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
            local poll_wait=2 poll_total=0 poll_max=300
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
            local merge_flag="--merge"
            local merge_subject="merge: $short_name — $title"
            if [[ "${MERGE_STRATEGY:-merge}" == "squash" ]]; then
                merge_flag="--squash"
                merge_subject="feat($epic_num): $title (#$pr_num)"
            fi

            cd "$repo_root" && gh pr merge "$pr_num" $merge_flag \
                --subject "$merge_subject" || {
                log ERROR "gh pr merge failed"
                return 1
            }
            log OK "PR #$pr_num merged"
            _emit_event "$events_log" "pr_merged" \
                "$(jq -nc --arg e "$epic_num" --argjson pr "$pr_num" '{epic:$e, pr:$pr}')"
            return 0
        fi

        # Still UNKNOWN after polling — keep waiting (do not rebase)
        if [[ "$mergeable" == "UNKNOWN" ]]; then
            log WARN "PR #$pr_num still UNKNOWN after polling — retrying (attempt $attempt/$max_retries)"
            sleep 5
            continue
        fi

        # CONFLICTING — rebase needed
        log WARN "PR not mergeable ($mergeable) — rebasing (attempt $attempt/$max_retries)"

        local head_before
        head_before=$(git -C "$repo_root" rev-parse HEAD)

        if ! _rebase_and_push "$repo_root" "$epic_num" "$short_name" "$title" "$events_log"; then
            return 1
        fi

        # If rebase was a no-op (HEAD unchanged), skip the push — already up-to-date
        local head_after
        head_after=$(git -C "$repo_root" rev-parse HEAD)
        if [[ "$head_before" == "$head_after" ]]; then
            log INFO "Rebase was a no-op — skipping redundant push"
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

    # Step 1: Switch to base branch FIRST (before any commits)
    git -C "$repo_root" checkout "$MERGE_TARGET" || {
        log WARN "Failed to checkout $MERGE_TARGET after merge — manual cleanup needed"
        return 0
    }
    git -C "$repo_root" pull origin "$MERGE_TARGET" || {
        log WARN "git pull failed — continuing"
    }

    # Step 2: Mark epic as merged on the BASE branch (durable state)
    if [[ -n "$epic_file" ]] && [[ -f "$epic_file" ]]; then
        mark_epic_merged "$epic_file" "$short_name"
        git -C "$repo_root" add "$epic_file"
        git -C "$repo_root" commit -m "fix($epic_num): mark epic YAML as merged" || true
        git -C "$repo_root" push origin "$MERGE_TARGET" || log WARN "Failed to push YAML marker"
    fi

    return 0
}

# ─── Internal Helpers ───────────────────────────────────────────────────────

source "${SCRIPT_DIR}/autopilot-coderabbit-helpers.sh"
