#!/usr/bin/env bash
# autopilot-review.sh — Tiered code review orchestrator
#
# Provides a tier-based review interface: each tier returns 0=clean,
# 1=issues found (TIER_OUTPUT set), 2=tier error (skip to next tier).
#
# Tiers:
#   1. CodeRabbit CLI (_tier_coderabbit_cli)
#   2. Codex (Phase 3 — placeholder)
#   3. Claude self-review (Phase 4 — placeholder)
#
# Sourced by autopilot.sh. Requires: autopilot-lib.sh (log),
# autopilot-review-helpers.sh (_review_is_clean, ensure_coderabbit_config,
# _classify_cr_error).

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ─── Tier Output ─────────────────────────────────────────────────────────────
# Set by tier functions when issues are found (return 1).
TIER_OUTPUT=""

_REVIEW_PATHSPEC_EXCLUDES=(
    ':(exclude)*.lock'
    ':(exclude)**/node_modules/**'
    ':(exclude)dist'
    ':(exclude)*.gen.*'
)

# ─── Tier 1: CodeRabbit CLI ─────────────────────────────────────────────────

# Tier 1: CodeRabbit CLI review
# Returns: 0=clean, 1=issues found (TIER_OUTPUT set), 2=tier error
_tier_coderabbit_cli() {
    local repo_root="$1" merge_target="$2"

    # Pre-flight: check availability
    if [[ "${HAS_CODERABBIT:-false}" != "true" ]]; then
        log INFO "CodeRabbit CLI not available — skipping tier"
        return 2
    fi

    # Ensure config exists (idempotent, ~5ms if exists)
    ensure_coderabbit_config "$repo_root"

    # Pre-flight: verify auth
    if ! coderabbit auth status >/dev/null 2>&1; then
        log WARN "CodeRabbit CLI not authenticated — skipping tier"
        return 2
    fi

    # Run coderabbit CLI with retry for transient errors
    local tmpfile rc=0 _cr_retry=0 _cr_max_retries=3
    local -a _backoff_secs=(10 30 60)
    while [[ $_cr_retry -lt $_cr_max_retries ]]; do
        tmpfile=$(mktemp)
        rc=0
        (cd "$repo_root" && coderabbit review --prompt-only --base "$merge_target" < /dev/null) \
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
                rate_limit|auth_error)
                    log WARN "CodeRabbit $_err_type — skipping tier"
                    return 2
                    ;;
                service_error)
                    local _wait=${_backoff_secs[$_cr_retry - 1]:-60}
                    log WARN "CodeRabbit service error (exit $rc) — retrying in ${_wait}s ($_cr_retry/$_cr_max_retries)"
                    sleep "$_wait"
                    ;;
                *)
                    log WARN "CodeRabbit CLI error (exit $rc) — retrying in 10s ($_cr_retry/$_cr_max_retries)"
                    sleep 10
                    ;;
            esac
        fi
    done

    # Final error after retries
    if [[ $rc -ne 0 ]]; then
        local output
        output=$(<"$tmpfile"); rm -f "$tmpfile"
        log WARN "CodeRabbit CLI failed after $_cr_retry retries"
        return 2
    fi

    TIER_OUTPUT=$(<"$tmpfile")
    rm -f "$tmpfile"

    if _review_is_clean "cli" "$TIER_OUTPUT"; then
        return 0
    fi
    return 1
}

# ─── Tier Orchestrator ────────────────────────────────────────────────────────

# Iterates configured tiers. On error (return 2), falls through to next tier.
# On clean (return 0) or issues-found (return 1), enters fix loop.
#
# Each tier function has the same interface:
#   _tier_<name>(repo_root, merge_target) → sets $TIER_OUTPUT, returns 0|1|2
#     0 = clean (no issues)
#     1 = issues found (output in TIER_OUTPUT)
#     2 = tier error (service down, auth fail, timeout)

_tiered_review() {
    local repo_root="$1"
    local merge_target="$2"
    local epic_num="$3"
    local title="$4"
    local short_name="$5"
    local events_log="$6"

    local tier_order
    IFS=',' read -ra tier_order <<< "${REVIEW_TIER_ORDER:-cli}"

    local tier_succeeded=false

    for tier in "${tier_order[@]}"; do
        tier=$(echo "$tier" | xargs)  # trim whitespace
        log INFO "Review tier: $tier"
        _emit_event "$events_log" "review_tier_start" "{\"tier\":\"$tier\"}"

        TIER_OUTPUT=""
        local rc=0

        case "$tier" in
            cli)    _tier_coderabbit_cli "$repo_root" "$merge_target" || rc=$? ;;
            codex)  _tier_codex "$repo_root" "$merge_target" || rc=$? ;;
            self)   _tier_claude_self_review "$repo_root" "$merge_target" "$epic_num" "$title" || rc=$? ;;
            *)      log WARN "Unknown review tier: $tier"; continue ;;
        esac

        case $rc in
            0)  # Clean — no issues
                LAST_CR_STATUS="clean (tier: $tier)"
                _emit_event "$events_log" "review_tier_end" "{\"tier\":\"$tier\",\"result\":\"clean\"}"
                tier_succeeded=true
                break
                ;;
            1)  # Issues found — enter fix loop; fall through to next tier if unresolved
                LAST_CR_STATUS="issues (tier: $tier)"
                _emit_event "$events_log" "review_tier_end" "{\"tier\":\"$tier\",\"result\":\"issues\"}"
                # Per-tier max rounds (Decision #17)
                local max_rounds
                case "$tier" in
                    cli)    max_rounds="${CODERABBIT_MAX_ROUNDS:-3}" ;;
                    codex)  max_rounds="${CODEX_MAX_ROUNDS:-3}" ;;
                    self)   max_rounds="${CLAUDE_SELF_REVIEW_MAX_ROUNDS:-2}" ;;
                    *)      max_rounds=3 ;;
                esac
                local loop_rc=0
                _review_fix_loop "$repo_root" "$merge_target" "$epic_num" "$title" "$short_name" "$tier" "$max_rounds" "$events_log" || loop_rc=$?
                if [[ $loop_rc -eq 0 ]]; then
                    tier_succeeded=true
                    break
                fi
                # loop_rc=1 (unresolved issues) or loop_rc=2 (tier error) — fall through
                log WARN "Tier '$tier' fix loop exited with rc=$loop_rc — falling through to next tier"
                ;;
            2)  # Tier error — fall through to next
                log WARN "Tier $tier failed — falling through to next tier"
                _emit_event "$events_log" "review_tier_end" "{\"tier\":\"$tier\",\"result\":\"error\"}"
                continue
                ;;
        esac
    done

    if ! $tier_succeeded; then
        LAST_CR_STATUS="all tiers failed"
        _emit_event "$events_log" "review_all_tiers_failed" "{}"
        # Apply existing FORCE_ADVANCE_ON_REVIEW_ERROR logic
        if [[ "${FORCE_ADVANCE_ON_REVIEW_ERROR:-false}" == "true" ]]; then
            log WARN "All review tiers failed — force-advancing (FORCE_ADVANCE_ON_REVIEW_ERROR=true)"
            return 0
        fi
        log ERROR "All review tiers failed"
        return 1
    fi

    return 0
}

# Convergence loop: re-run review tier, count issues, detect stall, invoke Claude fix.
# Each round: tier re-review → check clean → count issues → stall check → Claude fix → loop
#
# Parameters:
#   repo_root, merge_target, epic_num, title, short_name — pipeline context
#   tier       — which tier to re-run for re-review (cli|codex|self)
#   max_rounds — per-tier convergence limit (CLI=3, Codex=3, Claude=2)
#
# Returns: 0 (clean or force-advanced), 1 (halted — issues remain)

_review_fix_loop() {
    local repo_root="$1" merge_target="$2" epic_num="$3" title="$4"
    local short_name="$5" tier="$6" max_rounds="$7" events_log="$8"
    local attempt=0
    local -a _issue_counts=()

    while [[ $attempt -lt $max_rounds ]]; do
        attempt=$((attempt + 1))
        log INFO "$tier review-fix (round $attempt/$max_rounds)"
        _emit_event "$events_log" "review_convergence_round" \
            "{\"tier\":\"$tier\",\"round\":$attempt,\"max\":$max_rounds}"

        # ─ RE-REVIEW: Call the tier function directly ─
        local rc=0
        case "$tier" in
            cli)    _tier_coderabbit_cli "$repo_root" "$merge_target" || rc=$? ;;
            codex)  _tier_codex "$repo_root" "$merge_target" || rc=$? ;;
            self)   _tier_claude_self_review "$repo_root" "$merge_target" "$epic_num" "$title" || rc=$? ;;
            *)      log ERROR "Unknown tier: $tier"; return 1 ;;
        esac

        case $rc in
            0)  # Clean — all issues resolved
                LAST_CR_STATUS="clean (tier: $tier, round $attempt)"
                _emit_event "$events_log" "review_convergence_complete" \
                    "{\"tier\":\"$tier\",\"rounds_used\":$attempt,\"result\":\"clean\"}"
                return 0
                ;;
            2)  # Tier broke during re-review — signal caller to try next tier
                log WARN "Tier '$tier' errored during fix re-review — signaling fallthrough"
                LAST_CR_STATUS="tier error during fix (tier: $tier, round $attempt)"
                _emit_event "$events_log" "review_convergence_complete" \
                    "{\"tier\":\"$tier\",\"rounds_used\":$attempt,\"result\":\"tier_error\"}"
                return 2
                ;;
            1)  # Issues still found — continue convergence
                ;;
        esac

        # ─ CONVERGENCE TRACKING ─
        local issue_count
        issue_count=$(_count_review_issues "$tier" "$TIER_OUTPUT")
        _issue_counts+=("$issue_count")

        log WARN "$tier review found $issue_count issues (round $attempt/$max_rounds)"

        # Stall detection: identical issue counts for CONVERGENCE_STALL_ROUNDS rounds
        if _check_stall "${_issue_counts[*]}" "${CONVERGENCE_STALL_ROUNDS:-2}"; then
            if [[ "${FORCE_ADVANCE_ON_REVIEW_STALL:-false}" == "true" ]]; then
                LAST_CR_STATUS="force-advanced (stall, tier: $tier, round $attempt)"
                log WARN "Stalled — force-advancing"
                _emit_event "$events_log" "review_convergence_complete" \
                    "{\"tier\":\"$tier\",\"rounds_used\":$attempt,\"result\":\"force_advanced_stall\"}"
                return 0
            fi
            LAST_CR_STATUS="halted (stall, tier: $tier, round $attempt)"
            log ERROR "Stalled — halting"
            _emit_event "$events_log" "review_convergence_complete" \
                "{\"tier\":\"$tier\",\"rounds_used\":$attempt,\"result\":\"halted_stall\"}"
            return 1
        fi

        # Early exit: diminishing returns after 2+ rounds
        if [[ "${FORCE_ADVANCE_ON_DIMINISHING_RETURNS:-false}" == "true" ]] && [[ $attempt -ge ${DIMINISHING_RETURNS_THRESHOLD:-3} ]]; then
            LAST_CR_STATUS="force-advanced (diminishing returns, tier: $tier, round $attempt)"
            log WARN "Force-advancing after $attempt rounds (diminishing returns)"
            _emit_event "$events_log" "review_convergence_complete" \
                "{\"tier\":\"$tier\",\"rounds_used\":$attempt,\"result\":\"force_advanced_diminishing\"}"
            return 0
        fi

        # ─ CLAUDE FIX ─
        local fix_prompt
        fix_prompt="$(prompt_review_fix "$tier" "$epic_num" "$title" "$repo_root" "$short_name" "$TIER_OUTPUT")"
        invoke_claude "review-fix" "$fix_prompt" "$epic_num" "$title" || {
            log WARN "Review fix invocation failed (round $attempt)"
        }
        # Claude Code commits changes directly; next loop iteration re-reviews.
    done

    # After max_rounds exhausted
    if [[ "${FORCE_ADVANCE_ON_REVIEW_ERROR:-false}" == "true" ]]; then
        LAST_CR_STATUS="force-advanced (issues remain after $max_rounds rounds, tier: $tier)"
        log WARN "Issues remain after $max_rounds rounds — force-advancing"
        _emit_event "$events_log" "review_convergence_complete" \
            "{\"tier\":\"$tier\",\"rounds_used\":$max_rounds,\"result\":\"force_advanced_max\"}"
        return 0
    fi
    LAST_CR_STATUS="halted (issues remain after $max_rounds rounds, tier: $tier)"
    log ERROR "Issues remain after $max_rounds rounds"
    _emit_event "$events_log" "review_convergence_complete" \
        "{\"tier\":\"$tier\",\"rounds_used\":$max_rounds,\"result\":\"halted_max\"}"
    return 1
}

# ─── Tier 2: Codex Review ────────────────────────────────────────────────────
# Uses `codex exec --output-schema -o` with stdin prompt+diff (Decision #2).
# Guard-variable trap pattern (Decision #31). Process group isolation (Decision #25, #32).

_tier_codex() {
    local repo_root="$1" merge_target="$2"

    # Pre-flight: check availability
    if [[ "${HAS_CODEX:-false}" != "true" ]]; then
        log INFO "Codex CLI not available — skipping tier"
        return 2
    fi

    # Initialize before trap (prevents set -u crash in trap handler if mktemp fails)
    local tmpfile="" stderr_file="" prompt_file="" diff_file=""
    local timeout_secs="${CODEX_REVIEW_TIMEOUT:-300}"

    # ── CLEANUP: guard-variable pattern (Decision #31) ──
    # ERR+RETURN covers both set -e aborts and normal returns.
    # Guard variable (_codex_cleaned) makes handler idempotent:
    #   - Double-fire (ERR then RETURN in || context): harmless
    #   - Global pollution (trap leaks to caller): rm -f "" is a no-op
    # No "trap - ERR RETURN" lines needed — cleanup is unconditional.
    local _codex_cleaned=0
    _codex_cleanup() {
        [[ $_codex_cleaned -eq 1 ]] && return
        _codex_cleaned=1
        rm -f "$tmpfile" "$stderr_file" "$prompt_file" "$diff_file"
    }
    trap '_codex_cleanup' ERR RETURN
    tmpfile=$(mktemp)
    stderr_file=$(mktemp)
    prompt_file=$(mktemp)
    diff_file=$(mktemp)

    # ── DIFF SIZE GUARD ──
    git -C "$repo_root" diff "origin/${merge_target}...HEAD" \
        -- "${_REVIEW_PATHSPEC_EXCLUDES[@]}" > "$diff_file"
    local diff_bytes
    diff_bytes=$(wc -c < "$diff_file" | xargs)

    if [[ $diff_bytes -gt ${CODEX_MAX_DIFF_BYTES:-800000} ]]; then
        log WARN "Diff too large for Codex review (${diff_bytes} bytes, limit ${CODEX_MAX_DIFF_BYTES:-800000}) — falling through to next tier"
        return 2  # Tier 3 (Claude self-review) has chunking support
    fi

    # ── BUILD PROMPT FILE ──
    cat > "$prompt_file" <<'REVIEW_PROMPT'
You are a code reviewer. Review the following diff for bugs, security issues,
and correctness problems. Focus on actual defects, not style.

For each issue found, report with priority (0=critical, 1=high, 2=medium, 3=low),
confidence score (0-1), code location, description, and suggestion.

If no issues found, set overall_correctness to true with an empty findings array.
REVIEW_PROMPT
    # Append the cached diff
    cat "$diff_file" >> "$prompt_file"

    log INFO "Running codex review (timeout: ${timeout_secs}s, diff: ${diff_bytes} bytes)"

    # Process group isolation (see Decision #25, #32 for rationale)
    local rc=0
    run_with_timeout "$timeout_secs" \
        _exec_in_new_pgrp \
        bash -c 'cd "$1" && codex exec --sandbox read-only --ephemeral --output-schema "$2/codex-review-schema.json" -o "$3" - < "$4" 2>"$5"' \
        _ "$repo_root" "$SCRIPT_DIR" "$tmpfile" "$prompt_file" "$stderr_file" \
        || rc=$?

    if [[ $rc -eq 124 ]]; then
        log WARN "Codex review timed out after ${timeout_secs}s"
        [[ -s "$stderr_file" ]] && log WARN "Codex stderr (last 20 lines):" && \
            tail -20 "$stderr_file" | while IFS= read -r l; do log WARN "  $l"; done
        return 2  # tier error
    elif [[ $rc -ne 0 ]]; then
        log WARN "Codex review process error (exit $rc)"
        [[ -s "$stderr_file" ]] && log WARN "Codex stderr (last 20 lines):" && \
            tail -20 "$stderr_file" | while IFS= read -r l; do log WARN "  $l"; done
        return 2  # tier error
    fi

    if [[ ! -s "$tmpfile" ]]; then
        log WARN "Codex review produced no output"
        return 2
    fi

    # -o writes schema-conformant JSON directly (no JSONL extraction needed)
    TIER_OUTPUT=$(cat "$tmpfile")

    if [[ -z "$TIER_OUTPUT" ]]; then
        log WARN "Codex review: empty output file"
        return 2
    fi

    if _review_is_clean "codex" "$TIER_OUTPUT"; then
        return 0
    fi
    return 1
}

# ─── Tier 3: Claude Self-Review (Phase 4) ───────────────────────────────────

_tier_claude_self_review() {
    local repo_root="$1" merge_target="$2" epic_num="$3" title="$4"

    log INFO "Running Claude self-review (adversarial)"

    # Check diff size before sending
    local diff_bytes
    diff_bytes=$(git -C "$repo_root" diff "origin/${merge_target}...HEAD" \
        -- "${_REVIEW_PATHSPEC_EXCLUDES[@]}" \
        | wc -c | xargs)

    local est_tokens=$(( diff_bytes / 4 ))

    if [[ $est_tokens -gt 60000 ]]; then
        log WARN "Diff too large for self-review (~${est_tokens} tokens, limit 60000) — chunking by directory"
        _tier_claude_self_review_chunked "$repo_root" "$merge_target" "$epic_num" "$title"
        return $?
    fi

    local prompt
    prompt=$(prompt_self_review "$epic_num" "$title" "$repo_root" "$merge_target")

    # Use invoke_claude with self-review phase
    local tmpfile
    tmpfile=$(mktemp)
    if ! invoke_claude "self-review" "$prompt" "$epic_num" "$title" > "$tmpfile" 2>&1; then
        log WARN "Claude self-review failed"
        rm -f "$tmpfile"
        return 2
    fi

    TIER_OUTPUT=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if _review_is_clean "self" "$TIER_OUTPUT"; then
        return 0
    fi
    return 1
}

_tier_claude_self_review_chunked() {
    local repo_root="$1" merge_target="$2" epic_num="$3" title="$4"

    # Get changed first-level directories
    # First-level (backend/, frontend/, renderer/) keeps cross-cutting context together
    # and minimizes Claude invocations. Falls back to second-level only if a chunk
    # still exceeds 60K tokens.
    local dirs
    dirs=$(git -C "$repo_root" diff --name-only "origin/${merge_target}...HEAD" \
        -- "${_REVIEW_PATHSPEC_EXCLUDES[@]}" \
        | cut -d'/' -f1 | sort -u)

    local all_findings=""
    local chunk_num=0
    local success_count=0 fail_count=0

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        chunk_num=$((chunk_num + 1))

        # Note: chunk-scoped diffs intentionally omit _REVIEW_PATHSPEC_EXCLUDES
        # (pre-filtered by dir listing above; re-applying would misreport chunk sizes)
        local chunk_bytes
        chunk_bytes=$(git -C "$repo_root" diff "origin/${merge_target}...HEAD" -- "$dir" | wc -c | xargs)
        local chunk_tokens=$(( chunk_bytes / 4 ))

        if [[ $chunk_tokens -gt 60000 ]]; then
            # First-level chunk too large — fall back to second-level split
            log WARN "Chunk $dir too large (~${chunk_tokens} tokens) — splitting to second-level dirs"
            local subdirs
            subdirs=$(git -C "$repo_root" diff --name-only "origin/${merge_target}...HEAD" -- "$dir" \
                | cut -d'/' -f1-2 | sort -u)
            while IFS= read -r subdir; do
                [[ -z "$subdir" ]] && continue
                local sub_bytes
                sub_bytes=$(git -C "$repo_root" diff "origin/${merge_target}...HEAD" -- "$subdir" | wc -c | xargs)
                local sub_tokens=$(( sub_bytes / 4 ))
                if [[ $sub_tokens -gt 60000 ]]; then
                    log WARN "Sub-chunk $subdir still too large (~${sub_tokens} tokens) — skipping"
                    all_findings+="## $subdir\n\nSKIPPED: diff too large (~${sub_tokens} tokens)\n\n"
                    continue
                fi
                chunk_num=$((chunk_num + 1))
                log INFO "Self-review sub-chunk $chunk_num: $subdir"
                local sub_prompt
                sub_prompt=$(prompt_self_review_chunk "$epic_num" "$title" "$repo_root" "$merge_target" "$subdir")
                local sub_tmpfile
                sub_tmpfile=$(mktemp)
                if invoke_claude "self-review" "$sub_prompt" "$epic_num" "$title" > "$sub_tmpfile" 2>&1; then
                    all_findings+="## $subdir\n\n$(cat "$sub_tmpfile")\n\n"
                    success_count=$((success_count + 1))
                else
                    all_findings+="## $subdir\n\nREVIEW FAILED\n\n"
                    fail_count=$((fail_count + 1))
                fi
                rm -f "$sub_tmpfile"
            done <<< "$subdirs"
            continue
        fi

        log INFO "Self-review chunk $chunk_num: $dir"
        local prompt
        prompt=$(prompt_self_review_chunk "$epic_num" "$title" "$repo_root" "$merge_target" "$dir")

        local tmpfile
        tmpfile=$(mktemp)
        if invoke_claude "self-review" "$prompt" "$epic_num" "$title" > "$tmpfile" 2>&1; then
            all_findings+="## $dir\n\n$(cat "$tmpfile")\n\n"
            success_count=$((success_count + 1))
        else
            all_findings+="## $dir\n\nREVIEW FAILED\n\n"
            fail_count=$((fail_count + 1))
        fi
        rm -f "$tmpfile"
    done <<< "$dirs"

    # All chunks failed → tier error (fall through to next tier)
    if [[ $success_count -eq 0 ]]; then
        log WARN "All $fail_count review chunks failed — tier error"
        TIER_OUTPUT=""
        return 2
    fi

    # Partial failure → treat as issues (fix loop will re-review)
    if [[ $fail_count -gt 0 ]]; then
        log WARN "$fail_count/$((success_count + fail_count)) review chunks failed"
        TIER_OUTPUT="$all_findings"
        return 1
    fi

    # All succeeded → existing cleanness check
    TIER_OUTPUT="$all_findings"
    if _review_is_clean "self" "$TIER_OUTPUT"; then
        return 0
    fi
    return 1
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

source "${SCRIPT_DIR}/autopilot-review-helpers.sh"
