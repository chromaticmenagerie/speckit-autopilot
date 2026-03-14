#!/usr/bin/env bash
# autopilot-requirements.sh — Requirements verification gate.
# Inserted between implement-complete and security-review in the pipeline.
# Pattern follows _run_security_gate() in autopilot.sh.

set -euo pipefail

# Default for CLI flag (overridden by parse_args in autopilot.sh)
REQUIREMENTS_FORCE_SKIP_ALLOWED="${REQUIREMENTS_FORCE_SKIP_ALLOWED:-true}"

# ─── Requirements Gate ────────────────────────────────────────────────────

_run_requirements_gate() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" epic_file="$5"
    local spec_dir="$repo_root/specs/$short_name"
    local tasks_file="$spec_dir/tasks.md"
    local findings_file="$spec_dir/requirement-findings.md"
    local recheck_file="$spec_dir/requirement-recheck-findings.md"
    local max_rounds=${REQUIREMENTS_MAX_ROUNDS:-2}
    [[ $max_rounds -lt 1 ]] && max_rounds=1

    log PHASE "Requirements verification gate (max $max_rounds rounds)"

    # Resume guard: check for prior halt
    if grep -q '<!-- REQUIREMENTS_FORCE_SKIPPED -->' "$tasks_file" 2>/dev/null; then
        if [[ "$REQUIREMENTS_FORCE_SKIP_ALLOWED" != "true" ]]; then
            log ERROR "Requirements verification previously halted (--strict mode). Remove --strict to allow auto-advance."
            return 1
        fi
        # Force-advance: add verified marker
        sed '/<!-- REQUIREMENTS_FORCE_SKIPPED -->/a\
<!-- REQUIREMENTS_VERIFIED -->' "$tasks_file" > "$tasks_file.tmp" && \
        mv "$tasks_file.tmp" "$tasks_file"
        git -C "$repo_root" add "$tasks_file" && \
        git -C "$repo_root" commit -m "chore($epic_num): force-advance requirements verification" --no-verify 2>/dev/null || true
        log WARN "Requirements verification force-advanced"
        return 0
    fi

    # Pre-compute: extract FRs from spec
    local spec_file="$spec_dir/spec.md"
    local fr_list
    fr_list=$(grep -oE 'FR-[0-9]{3}' "$spec_file" 2>/dev/null | sort -u)

    if [[ -z "$fr_list" ]]; then
        log OK "No FR-NNN identifiers found in spec — skipping requirements verification"
        echo '<!-- REQUIREMENTS_VERIFIED -->' >> "$tasks_file"
        git -C "$repo_root" add "$tasks_file" && \
        git -C "$repo_root" commit -m "chore($epic_num): requirements verified (no FRs)" --no-verify 2>/dev/null || true
        return 0
    fi

    # Initialize findings file
    cat > "$findings_file" <<FINDINGS_HEADER
# Requirement Verification Findings
Epic: $epic_num — $title
FINDINGS_HEADER

    rm -f "$recheck_file" 2>/dev/null

    local round=1
    while [[ $round -le $max_rounds ]]; do
        log PHASE "Requirements verification round $round/$max_rounds"
        rm -f "$recheck_file" 2>/dev/null

        # Build evidence: grep for each FR's key terms in source
        local evidence=""
        while read -r fr; do
            local fr_context
            fr_context=$(grep -n "$fr" "$spec_file" 2>/dev/null | head -3)
            local code_refs
            code_refs=$(grep -rl "$fr" "$repo_root" \
                --include='*.go' --include='*.ts' --include='*.tsx' \
                --include='*.js' --include='*.jsx' --include='*.py' --include='*.rs' \
                --exclude-dir=vendor --exclude-dir=.git --exclude-dir=node_modules \
                --exclude-dir=specs --exclude-dir=docs 2>/dev/null | head -5 || true)
            evidence+="### $fr
Spec context: $fr_context
Code references: ${code_refs:-NONE FOUND}

"
        done <<< "$fr_list"

        # Write evidence to temp file for prompt
        local evidence_file
        evidence_file=$(mktemp "${TMPDIR:-/tmp}/req-evidence-XXXXXX")
        printf '%s' "$evidence" > "$evidence_file"

        # Invoke Claude to classify each FR
        local prompt
        prompt=$(prompt_verify_requirements "$epic_num" "$title" "$repo_root" "$short_name" "$evidence_file" "$findings_file" "$round" "$max_rounds")
        invoke_claude "verify-requirements" "$prompt" "$epic_num" "$title"
        local exit_code=$?
        rm -f "$evidence_file"
        _accumulate_phase_cost "$repo_root"

        if [[ $exit_code -ne 0 ]]; then
            log ERROR "Requirements verification failed (round $round)"
            ((round++))
            continue
        fi

        # Extract latest round for scoped parsing
        local latest_round
        latest_round=$(awk '/^## Round '"$round"'/{found=1} found' "$findings_file")
        [[ -z "$latest_round" ]] && latest_round=$(cat "$findings_file")

        # Parse findings: classify NOT_FOUND vs PARTIAL separately
        local has_not_found=false has_partial=false
        grep -qE ': NOT_FOUND' <<< "$latest_round" 2>/dev/null && has_not_found=true
        grep -qE ': PARTIAL' <<< "$latest_round" 2>/dev/null && has_partial=true

        if [[ "$has_not_found" == "true" ]] || [[ "$has_partial" == "true" ]]; then
            log WARN "Requirements gaps found (NOT_FOUND=$has_not_found, PARTIAL=$has_partial) — dispatching fix"

            # Extract failing FRs for scoped re-implement
            local failing_frs
            failing_frs=$(grep -E '(NOT_FOUND|PARTIAL)' <<< "$latest_round" | grep -oE 'FR-[0-9]{3}' | sort -u)

            local head_before
            head_before=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)

            local fix_prompt
            fix_prompt=$(prompt_requirements_fix "$epic_num" "$title" "$repo_root" "$short_name" "$findings_file" "$failing_frs")
            invoke_claude "requirements-fix" "$fix_prompt" "$epic_num" "$title" || true
            _accumulate_phase_cost "$repo_root"

            # 9c: Diagnostic warning
            if ! git -C "$repo_root" diff --quiet 2>/dev/null; then
                log WARN "requirements-fix left uncommitted changes — these will be visible in next round's verification"
            fi

            # 9d: Zero-commit check
            local head_after
            head_after=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)
            if [[ "$head_after" == "$head_before" ]]; then
                log WARN "requirements-fix produced no commits — skipping recheck"
                ((round++))
                continue
            fi

            # 9e: Build evidence and invoke requirements-recheck
            cat > "$recheck_file" <<RECHECK_HEADER
# Requirement Recheck Findings
Epic: $epic_num — $title
RECHECK_HEADER

            local recheck_evidence
            recheck_evidence=$(mktemp /tmp/req-recheck-evidence-XXXXXX)
            git -C "$repo_root" diff "$head_before"..HEAD > "$recheck_evidence" 2>/dev/null || true

            local recheck_prompt
            recheck_prompt=$(prompt_requirements_recheck "$epic_num" "$title" "$repo_root" "$short_name" \
                "$recheck_file" "$recheck_evidence" "$findings_file" "$failing_frs" "$round" "$max_rounds")
            invoke_claude "requirements-recheck" "$recheck_prompt" "$epic_num" "$title" || true
            _accumulate_phase_cost "$repo_root"
            rm -f "$recheck_evidence" 2>/dev/null

            # 9f: Parse verdict
            local recheck_verdict
            recheck_verdict=$(grep -i '^Verdict:' "$recheck_file" 2>/dev/null | tail -1 | awk '{print toupper($2)}')

            if [[ "$recheck_verdict" == "PASS" ]]; then
                log OK "Requirements recheck PASS — fixes verified"
                echo '<!-- REQUIREMENTS_VERIFIED -->' >> "$tasks_file"
                git -C "$repo_root" add "$tasks_file" "$findings_file"
                [[ -f "$recheck_file" ]] && git -C "$repo_root" add "$recheck_file"
                git -C "$repo_root" commit -m "chore($epic_num): requirements verified (recheck pass)" --no-verify
                return 0
            fi

            log WARN "Requirements recheck FAIL — bouncing back to full verify-requirements scan"
            ((round++))
            continue
        fi

        # All PASS — write marker and commit
        log OK "All requirements verified"
        echo '<!-- REQUIREMENTS_VERIFIED -->' >> "$tasks_file"
        git -C "$repo_root" add "$tasks_file" "$findings_file"
        [[ -f "$recheck_file" ]] && git -C "$repo_root" add "$recheck_file"
        git -C "$repo_root" commit -m "chore($epic_num): requirements verified" --no-verify 2>/dev/null || true
        return 0
    done

    # Exhausted rounds — compute coverage percentage
    log ERROR "Requirements verification failed after $max_rounds rounds"

    # Extract latest round for exhaustion formula
    local latest_round_final
    latest_round_final=$(awk '/^## Round '"$max_rounds"'/{found=1} found' "$findings_file")
    [[ -z "$latest_round_final" ]] && latest_round_final=$(cat "$findings_file")

    local pass_count partial_count deferred_count not_found_count actionable safe_count pct
    pass_count=$(grep -c ': PASS' <<< "$latest_round_final" 2>/dev/null) || true
    partial_count=$(grep -c ': PARTIAL' <<< "$latest_round_final" 2>/dev/null) || true
    deferred_count=$(grep -c ': DEFERRED' <<< "$latest_round_final" 2>/dev/null) || true
    not_found_count=$(grep -c ': NOT_FOUND' <<< "$latest_round_final" 2>/dev/null) || true
    safe_count=$((pass_count + partial_count))
    actionable=$((pass_count + partial_count + not_found_count))

    if [[ $actionable -eq 0 ]]; then
        log OK "All FRs deferred — requirements trivially satisfied"
        echo '<!-- REQUIREMENTS_VERIFIED -->' >> "$tasks_file"
        git -C "$repo_root" add "$tasks_file" "$findings_file"
        [[ -f "$recheck_file" ]] && git -C "$repo_root" add "$recheck_file"
        git -C "$repo_root" commit -m "chore($epic_num): requirements verified (all deferred)" --no-verify
        return 0
    fi
    pct=$((safe_count * 100 / actionable))
    log INFO "FR coverage: ${safe_count}/${actionable} (${pct}%) — ${deferred_count} deferred, threshold: 80%"

    echo '<!-- REQUIREMENTS_FORCE_SKIPPED -->' >> "$tasks_file"
    git -C "$repo_root" add "$tasks_file" "$findings_file"
    [[ -f "$recheck_file" ]] && git -C "$repo_root" add "$recheck_file"
    git -C "$repo_root" commit -m "chore($epic_num): requirements verification halted" --no-verify 2>/dev/null || true

    if [[ "$REQUIREMENTS_FORCE_SKIP_ALLOWED" == "true" ]]; then
        if [[ $pct -ge 80 ]]; then
            log WARN "FR coverage above 80% — auto-advancing despite gaps"
            # Write audit trail for force-skipped findings
            local skip_text
            skip_text=$(grep -E ': (NOT_FOUND|PARTIAL)' "$findings_file" 2>/dev/null || true)
            local skip_count
            skip_count=$((partial_count + not_found_count))
            if type _write_force_skip_audit &>/dev/null; then
                _write_force_skip_audit "$repo_root" "requirements-verification" \
                    "$epic_num" "$short_name" "$skip_count" "$skip_text" "WARN"
            fi
            echo '<!-- REQUIREMENTS_VERIFIED -->' >> "$tasks_file"
            git -C "$repo_root" add "$tasks_file" && \
            git -C "$repo_root" commit -m "chore($epic_num): requirements force-advanced (${pct}%)" --no-verify 2>/dev/null || true
            log WARN "Requirements verification force-advanced (auto-advance enabled)"
            return 0
        else
            log ERROR "FR coverage below 80% — halting"
            return 1
        fi
    fi

    return 1
}
