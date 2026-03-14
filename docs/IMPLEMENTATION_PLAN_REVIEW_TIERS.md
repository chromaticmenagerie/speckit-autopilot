# Implementation Plan: 3-Tier Review Fallback (v0.9.6)

> **Version**: 1.8 — 15 validated amendments applied from 9 rounds of repercussions analysis.
> Consolidated from 9 rounds of repercussions analysis + fix validation.
> Amendments 13-15 (Decisions 30-32): wait -n race recovery, guard-variable trap pattern, _exec_in_new_pgrp with exec prefix.
> All recommendations verified against actual codebase, consumer repos, online docs, and live CLI testing.

## Overview

Replace the single-point-of-failure CodeRabbit CLI review with a 3-tier fallback system. Each tier has genuinely independent infrastructure, so a CodeRabbit outage doesn't block the pipeline.

| Tier | Tool | Infrastructure | Invocation |
|------|------|----------------|------------|
| 1 | CodeRabbit CLI (direct) | CodeRabbit cloud + binary | `coderabbit review --prompt-only --base "origin/$merge_target"` |
| 2 | Codex review | OpenAI cloud + binary | `codex exec --output-schema codex-review-schema.json -o "$tmpfile" - < "$prompt_file"` |
| 3 | Claude self-review | Anthropic API (already required) | `invoke_claude "self-review" "$prompt"` |

**Dropped**: CodeRabbit-via-Claude-plugin (Tier 2 in original plan). Investigation confirmed the plugin is just a prompt template that calls the same `coderabbit` CLI binary — identical failure mode as Tier 1. Not an independent fallback.

---

## Decisions Log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | 3 tiers, not 4 | CR plugin shares CR CLI failure mode — not independent |
| 2 | `codex exec --output-schema -o` with stdin prompt+diff | `codex exec review --base` is non-functional (`review` is prompt text, `--base` doesn't exist). Pre-compute diff in shell (git diff broken in Codex sandbox per issue #6688). Pipe prompt+diff via stdin (`- < "$prompt_file"`). Use `--output-schema` for structured JSON (bug #4181 fixed in PR #4195, Sept 2025). Use `-o` for file output (compatible per OpenAI Cookbook). Eliminates jq JSONL parsing entirely. |
| 3 | `wait -n` bash pattern for timeout | Zero dependencies; bash 5.3.9 supports it; avoids `brew install coreutils` requirement |
| 4 | Opus for Claude self-review | Review requires strong reasoning (correctness, security, architecture); consistent with existing `PHASE_MODEL[review]="$OPUS"` |
| 5 | 60K token diff size limit before chunking | ~240KB raw diff; leaves room for system prompt + review output within 200K context window; chunk by first-level directory |
| 6 | Clean rename (no wrapper/stub) | Zero external references to old filenames; install.sh handles propagation atomically; wrapper adds permanent maintenance burden |
| 7 | Version 0.9.6 | Minor patch increment |
| 8 | Pre-computed diff via stdin; structured output via --output-schema | Codex sandbox (read-only) blocks git diff (macOS Seatbelt restricts /tmp writes, issue #6688, still open). Pre-compute diff in shell, append to prompt file, pipe via stdin. `--output-schema` enforces JSON structure (findings[], overall_correctness, priority 0-3). Keep grep-fallback for when schema is silently dropped. |
| 9 | First-level dir chunking (`backend/`, `frontend/`) | Fewer Claude invocations; first-level dirs are already well-scoped; reviewers need cross-cutting context (e.g., handler + validation changes together). Fall back to second-level only if a first-level chunk still exceeds 60K tokens |
| 10 | Create `AGENTS.md` at repo root | Codex reads `AGENTS.md` per official docs (not `.codex/instructions.md` — `.codex/` is only for `config.toml`). No mkdir needed; simpler deployment. Teams use `AGENTS.override.md` for custom instructions. Content deployed via `update_managed_section()` (marker-based fenced section in common.sh) to avoid overwriting speckit-core's agent context. |
| 11 | Skip per-tier cost tracking | Codex costs are external (OpenAI billing); only Claude tiers go through `invoke_claude` which already tracks cost. Not worth the complexity |
| 12 | Phase array entries inline in `declare -A` | ~~Originally: post-block assignments required.~~ Superseded by Decision #29. Self-references (`${PHASE_MODEL[key]}`) fail inside `declare -A` blocks, but all entries use external variables (`$OPUS`, `$SONNET`) which resolve correctly. New entries go inline alongside existing ones. `coderabbit-fix` is actively used (line 293). |
| 13 | `git diff` (not `--stat`) for diff size estimation | `--stat` outputs summary text (~500 bytes) regardless of actual diff size; undercounts by 50-110x. Full `git diff \| wc -c` is accurate and sub-30ms for typical PR diffs |
| 14 | `AGENTS.md` at repo root (not `.codex/instructions.md`) | Codex CLI reads `AGENTS.md` per official discovery algorithm; `.codex/instructions.md` is not a recognized path. No conflict with `CLAUDE.md` — each tool reads its own file. Ownership conflict with speckit-core's `update-agent-context.sh` resolved via marker-based sections (`<!-- BEGIN SPECKIT-AUTOPILOT MANAGED BLOCK -->`). Each tool owns its own block; content outside blocks is preserved. |
| 15 | `prompt_review_fix()` preserves all `_preamble()` params | Constitutional context + architecture reading are non-negotiable per preamble contract. All fix-phase prompts call `_preamble(epic_num, title, repo_root)` and use `epic_num` in commit messages — `prompt_review_fix()` must follow the same pattern |
| 16 | Direct JSON via `-o` flag (no JSONL parsing) | `-o "$tmpfile"` writes schema-conformant JSON directly. `TIER_OUTPUT=$(cat "$tmpfile")` — no jq JSONL extraction. jq still needed in helper functions for JSON field parsing but jq-for-JSONL is eliminated. |
| 17 | Per-tier `max_rounds` as parameter to `_review_fix_loop()` | Each tier sets its own convergence limit: CLI=2, Codex=2, Claude self-review=2. Passed as parameter, not global config. Inner retry (transient errors) stays in tier functions; outer convergence (fix loop) in `_review_fix_loop()` |
| 18 | `ensure_coderabbit_config` after `HAS_CODERABBIT` check | Don't create .coderabbit.yaml when CLI not installed; avoids wasteful file I/O and git noise. Function is idempotent (~5ms on subsequent calls). |
| 19 | `"rebase-fix"` phase for post-rebase test fixes | Line 400 reuses `"coderabbit-fix"` for test failures (with `prompt_finalize_fix()`), not review fixes. Different semantics → different phase name. Dashboard shows accurate phase. |
| 20 | `[[ -v ]]` guard in `invoke_claude()` | Missing associative array key + `set -u` = crash with confusing "unbound variable" error. Guard catches misconfiguration gracefully. `[[ -v array[key] ]]` requires bash 4.3+ (aligned with version guard bump). Fixes latent bug in 8 direct-call sites that bypass `run_phase()` validation. |
| 21 | jq-first, grep-fallback for Codex output | `agent_message.text` format is model-dependent (JSON or plain text). jq handles structured JSON; grep handles text with `[P0]` markers. `(.findings // [])` null-guard prevents false "clean" on missing key. `(.priority // 99)` prevents jq's `null <= 2 = true` gotcha. Parentheses are essential for operator precedence. |
| 22 | `--output-schema` IS viable (primary parsing path) | Bug #4181 (silent schema drop on Codex-branded models) fixed in PR #4195, merged Sept 2025. `codex exec --output-schema schema.json` works on current CLI (v0.113.0+). `-o` + `--output-schema` confirmed compatible (OpenAI Cookbook). Schema uses OpenAI Structured Outputs format (requires `additionalProperties: false` at each object level). |
| 23 | `trap ERR RETURN` (not just RETURN) for cleanup | `trap RETURN` does NOT fire when `set -e` aborts a function — temp files leak. `trap ERR RETURN` covers both paths. Must unset with `trap - ERR RETURN` before returning because bash traps are global per signal, not lexically scoped. Variables initialized to `""` before trap to prevent `set -u` crash in handler. |
| 24 | stderr to temp file, not `/dev/null` | Codex auth failures and rate limits may go to stderr only (not as JSONL error events). Redirect to temp file; log last 20 lines on failure for diagnostics. Cleaned up by ERR RETURN trap. |
| 25 | `perl -e 'setpgrp(0,0); exec @ARGV'` for process group isolation | Only reliable cross-platform (macOS+Linux) approach with zero external dependencies. `set -m` inside `bash -c` does NOT make it a group leader (only affects children); `kill 0` would kill parent script. `setsid` CLI is Linux-only. `timeout` requires coreutils. perl ships on all macOS through Tahoe 26. |
| 26 | `kill -- -"$cmd_pid"` in `run_with_timeout` | Kills entire process group (negative PID). Required because Codex CLI does NOT self-terminate on parent death (issues #4337, #7985, #7852). Orphaned processes continue API calls ($0.50-$5.00/orphan in tokens). |
| 27 | Marker-based fenced sections for AGENTS.md | speckit-core's `update-agent-context.sh` also writes AGENTS.md. `cp` would destroy its content. `update_managed_section()` in common.sh replaces only the `<!-- BEGIN SPECKIT-AUTOPILOT MANAGED BLOCK -->` section. Marker naming: fully qualified (`SPECKIT-AUTOPILOT`, `SPECKIT-CORE`). Existing `<!-- MANUAL ADDITIONS -->` markers unchanged. No file locking (both tools are manual scripts). |
| 28 | SIGKILL escalation after SIGTERM in `run_with_timeout` | SIGTERM can be caught, blocked, or ignored. Codex CLI has multiple open hanging issues (#7187, #13715, #14048) where processes don't respond to SIGTERM. Without SIGKILL fallback, `wait $pid` hangs forever. Add 2s grace period after SIGTERM, then `kill -9 -- -$pid` (SIGKILL, uncatchable). Process group still alive check via `kill -0 -- -$pid`. |
| 29 | Phase array entries: inline in `declare -A` is fine | Decision #12 conflated self-references (`${PHASE_MODEL[key]}`) with external variables (`$OPUS`). All entries use external variables defined before the block — these resolve correctly inside `declare -A`. New entries (`[review-fix]="$OPUS"`, etc.) can go inline. No need to remove existing `[coderabbit-fix]` entries or use post-block assignments. Original concern is only valid for self-references, which are not used. |
| 30 | `wait -n` exit 127 recovery path in `run_with_timeout` | Race condition: bash SIGCHLD handler can reap child before `wait -n` collects it → returns 127 instead of real exit code (acknowledged by Chet Ramey, not fixed in any bash version). Recovery: `wait "$cmd_pid"` (explicit PID) retrieves cached status per POSIX spec. Use `&& first_status=$? \|\| first_status=$?` pattern to prevent `set -e` abort on non-zero exit. Current `kill -0` check correctly routes timeout-vs-completion but would return wrong exit code (127) without recovery. |
| 31 | Guard-variable trap pattern (not subshell) for `_tier_codex` cleanup | Subshell `trap EXIT` refactor rejected: (a) `TIER_OUTPUT=$(...)` under `set -e` aborts parent before `rc=$?` executes — showstopper; (b) exit code granularity lost (5 distinct non-zero paths collapse to 1); (c) orphaned background processes on subshell kill. Instead: keep `trap ERR RETURN`, add `_codex_cleanup()` with `_codex_cleaned` guard variable, remove ALL `trap - ERR RETURN` lines. Guard makes handler idempotent; `rm -f ""` is a no-op for out-of-scope locals. Other tiers use simple explicit cleanup — no consistency concern. |
| 32 | `_exec_in_new_pgrp()` wrapper with `exec` prefix mandatory | Without `exec`, bash forks subshell (PID S) then perl (PID X). `$!`=S but `setpgrp` makes X the PGID leader. `kill -- -S` targets parent's PGID — catastrophic. With `exec`, subshell replaces itself: `$!`=X=PGID leader. python3 fallback uses identical `os.setpgrp()` syscall; 51ms startup (vs perl 4ms) acceptable for once-per-review. `"$@"` passes args transparently through both `exec @ARGV` (perl) and `os.execvp` (python3). |

---

## File Impact Summary

| File | Action | Est. Lines |
|------|--------|-----------|
| `src/autopilot-coderabbit.sh` → `src/autopilot-review.sh` | Rename + refactor | ~130 existing (after dead fn removal) + ~180 new |
| `src/autopilot-coderabbit-helpers.sh` → `src/autopilot-review-helpers.sh` | Rename + dead fn removal + tier dispatch + bug fixes | ~130 existing (after dead fn removal) + ~120 new |
| `src/autopilot-merge.sh` | **New** — extracted from autopilot-coderabbit.sh | ~270 |
| `src/autopilot-prompts.sh` | Add 4 prompt functions (`prompt_self_review`, `prompt_self_review_chunk`, `prompt_review_fix`, `prompt_coderabbit_fix` alias) | +~140 |
| `src/autopilot.sh` | Version guard 4.3 + source paths + phase arrays + invoke_claude guard | ~40 modified |
| `src/autopilot-lib.sh` | Add `run_with_timeout()` (with process group kill), `_exec_in_new_pgrp()`, Codex detection | ~55 new |
| `src/autopilot-detect-project.sh` | Add HAS_CODEX detection, `jq` detection, REVIEW_TIER_ORDER template | ~20 new |
| `install.sh` | Copy loop + cleanup + managed AGENTS.md deploy + schema file | ~25 modified |
| `src/codex-review-schema.json` | **New** — Codex structured output schema | ~25 |
| `tests/test-review-tiers.sh` | **New** — tier fallback + schema + AGENTS.md tests | ~250 |
| `tests/test-coderabbit-helpers.sh` → `tests/test-review-helpers.sh` | Rename + update source | ~10 modified |
| `VERSION` | Bump to 0.9.6 | 1 |
| `src/common.sh` | Add `update_managed_section()` | +~40 |

**Total**: ~765 new lines, ~130 modified. New file: `codex-review-schema.json` (added to install.sh copy loop). `jq` still needed in helper functions for JSON field parsing but JSONL extraction is eliminated.

---

## 1. File Renames & 3-File Split

### Current structure
```
src/autopilot-coderabbit.sh         (600 lines — review + merge + PR + cleanup)
src/autopilot-coderabbit-helpers.sh (173 lines — error classifiers, counters)
```

### New structure
```
src/autopilot-review.sh             (~290 lines — tier orchestrator + _coderabbit_cli_review)
src/autopilot-review-helpers.sh     (~250 lines — error classifiers, counters, tier dispatch)
src/autopilot-merge.sh              (~270 lines — do_remote_merge + rebase + PR + merge + cleanup)
```

### Why `do_remote_merge()` goes in autopilot-merge.sh

`do_remote_merge()` calls BOTH review and merge functions — it's the pipeline orchestrator. Placing it in `autopilot-review.sh` would be misleading. It belongs in `autopilot-merge.sh` where it thematically fits (orchestrating the merge pipeline, of which review is one step).

The cross-file call from `autopilot-merge.sh` → `autopilot-review.sh` (`_tiered_review()`) is clean: single call, exit-code-only coupling, no shared mutable state leaking across the boundary.

### Source chain

Flat sourcing from `autopilot.sh` (not cascading):

```bash
# autopilot.sh — replace line 29
source "$SCRIPT_DIR/autopilot-review-helpers.sh"  # helpers first (no deps)
source "$SCRIPT_DIR/autopilot-review.sh"           # uses helpers
source "$SCRIPT_DIR/autopilot-merge.sh"            # uses review + helpers
```

### Function placement

| Function | Current file | New file |
|----------|-------------|----------|
| `do_remote_merge()` (lines 25-135) | autopilot-coderabbit.sh | **autopilot-merge.sh** |
| `_coderabbit_cli_review()` (lines 141-307) | autopilot-coderabbit.sh | **autopilot-review.sh** (renamed to `_tier_coderabbit_cli()`) |
| `_rebase_and_push()` (lines 312-426) | autopilot-coderabbit.sh | **autopilot-merge.sh** |
| `_pr_body()` (lines 430-444) | autopilot-coderabbit.sh | **autopilot-merge.sh** |
| `_create_or_find_pr()` (lines 449-490) | autopilot-coderabbit.sh | **autopilot-merge.sh** |
| `_check_and_merge_pr()` (lines 495-570) | autopilot-coderabbit.sh | **autopilot-merge.sh** |
| `_post_merge_cleanup()` (lines 575-596) | autopilot-coderabbit.sh | **autopilot-merge.sh** |
| All helper functions | autopilot-coderabbit-helpers.sh | **autopilot-review-helpers.sh** |

---

## 2. Tier Orchestrator

### `_tiered_review()` — new function in `autopilot-review.sh`

```bash
# Iterates configured tiers. On error (return 2), falls through to next tier.
# On clean (return 0) or issues-found (return 1), enters existing fix loop.
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
            1)  # Issues found — enter fix loop
                LAST_CR_STATUS="issues (tier: $tier)"
                _emit_event "$events_log" "review_tier_end" "{\"tier\":\"$tier\",\"result\":\"issues\"}"
                # Per-tier max rounds (Decision #17)
                local max_rounds
                case "$tier" in
                    cli)    max_rounds="${CODERABBIT_MAX_ROUNDS:-2}" ;;
                    codex)  max_rounds="${CODEX_MAX_ROUNDS:-2}" ;;
                    self)   max_rounds="${CLAUDE_SELF_REVIEW_MAX_ROUNDS:-2}" ;;
                    *)      max_rounds=2 ;;
                esac
                _review_fix_loop "$repo_root" "$merge_target" "$epic_num" "$title" "$short_name" "$tier" "$max_rounds" "$events_log"
                tier_succeeded=true
                break
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
```

### Integration point

In `do_remote_merge()` (currently at line 85 of autopilot-coderabbit.sh), replace:

```bash
# OLD (line 85):
if [[ "${HAS_CODERABBIT:-false}" == "true" ]] && [[ "${SKIP_CODERABBIT:-false}" != "true" ]]; then
    _coderabbit_cli_review "$repo_root" "$merge_target" ...

# NEW:
if [[ "${SKIP_REVIEW:-${SKIP_CODERABBIT:-false}}" != "true" ]]; then
    _tiered_review "$repo_root" "$merge_target" "$epic_num" "$title" "$short_name" "$events_log"
```

Note: The `HAS_CODERABBIT` guard is removed from the top level. Individual tiers check their own availability (e.g., `_tier_coderabbit_cli` checks `HAS_CODERABBIT`, `_tier_codex` checks `HAS_CODEX`).

### `_review_fix_loop()` — convergence loop in `autopilot-review.sh`

Extracted from current `_coderabbit_cli_review()` outer loop (lines 155-296). Made tier-aware with per-tier `max_rounds`.

```bash
# Convergence loop: re-run review tier, count issues, detect stall, invoke Claude fix.
# Each round: tier re-review → check clean → count issues → stall check → Claude fix → loop
#
# Parameters:
#   repo_root, merge_target, epic_num, title, short_name — pipeline context
#   tier       — which tier to re-run for re-review (cli|codex|self)
#   max_rounds — per-tier convergence limit (CLI=2, Codex=2, Claude=2)
#
# Returns: 0 (clean or force-advanced), 1 (halted — issues remain)
#
# Design notes:
#   - Inner retry (transient errors like rate_limit, service_error) stays inside
#     each tier function. _review_fix_loop() only sees return codes 0|1|2.
#   - Re-review calls the original tier function directly (D3 pattern).
#     Pre-flight checks (auth, HAS_CODERABBIT) re-run each round — harmless
#     (~500ms overhead) and guards against mid-loop auth revocation.
#   - Between fix and re-review, nothing explicit happens — Claude Code commits
#     its changes directly. Next tier call sees committed code.
#   - If Claude fix fails (non-zero), loop continues. Stall detection catches
#     repeated identical issue counts. FORCE_ADVANCE can bypass.

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
        # Tier functions are idempotent; re-calling sees post-fix code state.
        # Inner retry (transient errors) is handled inside each tier function.
        # Return codes: 0=clean, 1=issues, 2=tier error
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
            2)  # Tier error during re-review (should be rare)
                log WARN "$tier re-review failed (round $attempt) — tier error in fix loop"
                _emit_event "$events_log" "review_convergence_complete" \
                    "{\"tier\":\"$tier\",\"rounds_used\":$attempt,\"result\":\"tier_error\"}"
                return 1
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
        if [[ "${FORCE_ADVANCE_ON_REVIEW_STALL:-false}" == "true" ]] && [[ $attempt -ge 2 ]]; then
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
```

### Per-tier convergence configuration

| Config | Tier 1 (CLI) | Tier 2 (Codex) | Tier 3 (Claude) | Scope |
|--------|-------------|----------------|-----------------|-------|
| `max_rounds` | `CODERABBIT_MAX_ROUNDS` (2) | `CODEX_MAX_ROUNDS` (2) | `CLAUDE_SELF_REVIEW_MAX_ROUNDS` (2) | Passed as param |
| Stall threshold | `CONVERGENCE_STALL_ROUNDS` (2) | Same global | Same global | Global config |
| Force-advance (stall) | `FORCE_ADVANCE_ON_REVIEW_STALL` | Same global | Same global | Global config |
| Force-advance (error) | `FORCE_ADVANCE_ON_REVIEW_ERROR` | Same global | Same global | Global config |
| Inner retry | 3 attempts, 10/30/60s backoff | No (Codex handles internally) | No (`invoke_claude` handles) | Per-tier function |

### State coupling: inner retry → outer convergence

Each tier function classifies transient vs terminal errors internally:
- **Terminal** (`rate_limit`, `auth_error`): tier returns 2 → `_tiered_review()` falls through to next tier. `_review_fix_loop()` is never called.
- **Transient** (`service_error`): tier retries with backoff internally. If all retries exhausted, returns 2 → next tier.
- **Success**: tier returns 0 (clean) or 1 (issues) → `_review_fix_loop()` handles convergence.

This coupling is **intentional**: rate-limited tiers should not block the pipeline. Terminal errors skip the fix loop entirely.

---

## 3. Tier Implementations

### Tier 1: CodeRabbit CLI (`_tier_coderabbit_cli`)

Extracted from current `_coderabbit_cli_review()` (lines 141-307). Core logic unchanged — just wrapped in the tier interface:

```bash
_tier_coderabbit_cli() {
    local repo_root="$1" merge_target="$2"

    # Pre-flight: check availability
    if [[ "${HAS_CODERABBIT:-false}" != "true" ]]; then
        log INFO "CodeRabbit CLI not available — skipping tier"
        return 2
    fi

    # Ensure config exists with sensible defaults (idempotent, ~5ms if file exists)
    ensure_coderabbit_config "$repo_root"

    # Run coderabbit CLI (extracted from current _coderabbit_cli_review)
    local tmpfile
    tmpfile=$(mktemp)
    if ! coderabbit review --prompt-only --base "origin/$merge_target" < /dev/null > "$tmpfile" 2>&1; then
        local err_class
        err_class=$(_classify_review_error "cli" "$(cat "$tmpfile")")
        log WARN "CodeRabbit CLI error: $err_class"
        rm -f "$tmpfile"
        return 2  # tier error — fall through
    fi

    TIER_OUTPUT=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if _review_is_clean "cli" "$TIER_OUTPUT"; then
        return 0  # clean
    fi
    return 1  # issues found
}
```

### Tier 2: Codex Review (`_tier_codex`)

Uses `codex exec --output-schema -o` with stdin prompt+diff (Decision #2). Key design:
- Pre-compute diff in shell (git diff broken in Codex sandbox per issue #6688)
- Pipe prompt+diff via stdin (`- < "$prompt_file"`)
- `--output-schema` enforces JSON structure (bug #4181 fixed in PR #4195)
- `-o "$tmpfile"` captures schema-conformant JSON directly (no JSONL parsing)
- Diff size guard: `CODEX_MAX_DIFF_BYTES` (default 800000, ~200K tokens, under Codex's 258K CLI limit). Returns 2 if exceeded → Tier 3 has chunking
- `AGENTS.md` provides project-specific context to reduce false positives

```bash
_tier_codex() {
    local repo_root="$1" merge_target="$2"

    # Pre-flight: check availability
    if [[ "${HAS_CODEX:-false}" != "true" ]]; then
        log INFO "Codex CLI not available — skipping tier"
        return 2
    fi

    # Initialize before trap (prevents set -u crash in trap handler if mktemp fails)
    local tmpfile="" stderr_file="" prompt_file=""
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
        rm -f "$tmpfile" "$stderr_file" "$prompt_file"
    }
    tmpfile=$(mktemp)
    stderr_file=$(mktemp)
    prompt_file=$(mktemp)
    trap '_codex_cleanup' ERR RETURN

    # ── DIFF SIZE GUARD ──
    local diff_bytes
    diff_bytes=$(git -C "$repo_root" diff "origin/${merge_target}...HEAD" \
        -- ':(exclude)*.lock' ':(exclude)node_modules' ':(exclude)dist' ':(exclude)*.gen.*' \
        | wc -c | xargs)

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
    # Append the actual diff
    git -C "$repo_root" diff "origin/${merge_target}...HEAD" \
        -- ':(exclude)*.lock' ':(exclude)node_modules' ':(exclude)dist' ':(exclude)*.gen.*' \
        >> "$prompt_file"

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
```

### Tier 3: Claude Self-Review (`_tier_claude_self_review`)

```bash
_tier_claude_self_review() {
    local repo_root="$1" merge_target="$2" epic_num="$3" title="$4"

    log INFO "Running Claude self-review (adversarial)"

    # Check diff size before sending
    local diff_bytes
    diff_bytes=$(git -C "$repo_root" diff "origin/${merge_target}...HEAD" \
        -- ':(exclude)*.lock' ':(exclude)node_modules' ':(exclude)dist' ':(exclude)*.gen.*' \
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
        -- ':(exclude)*.lock' ':(exclude)node_modules' ':(exclude)dist' ':(exclude)*.gen.*' \
        | cut -d'/' -f1 | sort -u)

    local all_findings=""
    local chunk_num=0

    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        chunk_num=$((chunk_num + 1))

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
                else
                    all_findings+="## $subdir\n\nREVIEW FAILED\n\n"
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
        else
            all_findings+="## $dir\n\nREVIEW FAILED\n\n"
        fi
        rm -f "$tmpfile"
    done <<< "$dirs"

    TIER_OUTPUT="$all_findings"

    if _review_is_clean "self" "$TIER_OUTPUT"; then
        return 0
    fi
    return 1
}
```

---

## 4. Generalized Helpers (`autopilot-review-helpers.sh`)

### Tier-aware dispatch functions

Replace existing functions with tier-aware versions. Old names kept as aliases during the transition period within the same file:

```bash
# Tier-aware cleanness check
_review_is_clean() {
    local tier="$1" output="$2"
    case "$tier" in
        cli)    _cr_cli_is_clean "$output" ;;    # existing logic unchanged
        codex)  _codex_is_clean "$output" ;;
        self)   _self_review_is_clean "$output" ;;
        *)      return 1 ;;
    esac
}

# Tier-aware issue counting
_count_review_issues() {
    local tier="$1" output="$2"
    case "$tier" in
        cli)    _count_cli_issues "$output" ;;   # existing logic unchanged
        codex)  _count_codex_issues "$output" ;;
        self)   _count_self_issues "$output" ;;
        *)      echo 0 ;;
    esac
}

# Tier-aware error classification
_classify_review_error() {
    local tier="$1" output="$2"
    case "$tier" in
        cli)    _classify_cr_error "$output" ;;  # existing logic unchanged
        codex)  _classify_codex_error "$output" ;;
        self)   echo "claude_error" ;;            # Anthropic API errors
        *)      echo "unknown" ;;
    esac
}
```

### New classifier functions

```bash
# Codex output parsing — jq-first, grep-fallback
# agent_message.text may be JSON ({"findings":[...]}) or plain text with [P0]-[P3] markers.
# jq is guaranteed available (gated by _tier_codex pre-flight check).
#
# IMPORTANT: Parentheses in (.findings // []) are ESSENTIAL.
# Without them: .findings // [] | length == 0
#   parses as: .findings // ([] | length == 0) → .findings // true — WRONG.
# With them: (.findings // []) | length == 0
#   parses as: (fallback to []) | length == 0 — CORRECT.

_codex_is_clean() {
    local output="$1"
    [[ -z "$output" ]] && return 1  # empty = error, not clean

    # Primary: structured output via --output-schema (overall_correctness field)
    local correctness
    correctness=$(echo "$output" | jq -r '.overall_correctness // empty' 2>/dev/null) || true
    if [[ "$correctness" == "true" ]]; then
        # Cross-check: no P0/P1 findings despite overall_correctness=true
        local high_count
        high_count=$(echo "$output" | jq '[(.findings // [])[] | select((.priority // 99) <= 1)] | length' 2>/dev/null) || high_count=0
        [[ "$high_count" -eq 0 ]] && return 0
        return 1  # contradictory — conservative
    elif [[ "$correctness" == "false" ]]; then
        return 1
    fi

    # Fallback: JSON path (findings array, no overall_correctness)
    local jq_rc=0
    echo "$output" | jq -e '(.findings // []) | length == 0' >/dev/null 2>&1 || jq_rc=$?
    case $jq_rc in
        0) return 0 ;;  # JSON parsed, findings empty → clean
        1) return 1 ;;  # JSON parsed, findings non-empty → issues
        # 4|5 = not valid JSON → fall through to text parsing
    esac

    # Text path: P0-P2 severity markers (grep-fallback for when schema silently dropped)
    if echo "$output" | grep -qE '\[P[0-2]\]'; then
        return 1
    fi

    # Clean language indicators
    if echo "$output" | grep -qi "no issues\|no findings\|no problems\|appears correct\|no defects\|patch is correct"; then
        return 0
    fi

    return 1  # conservative default
}

_count_codex_issues() {
    local output="$1"
    [[ -z "$output" ]] && echo "0" && return

    # JSON path: count findings with priority <= 2 (P0-P2)
    # (.priority // 99) prevents null <= 2 evaluating to true in jq
    local jq_count
    jq_count=$(echo "$output" | jq '[(.findings // [])[] | select((.priority // 99) <= 2)] | length' 2>/dev/null) || jq_count=""
    if [[ -n "$jq_count" ]] && [[ "$jq_count" =~ ^[0-9]+$ ]]; then
        echo "$jq_count"
        return
    fi

    # Text path: count P0-P2 marker lines
    local count
    count=$(echo "$output" | grep -coE '\[P[0-2]\]' 2>/dev/null) || count=0
    echo "$count"
}

_classify_codex_error() {
    local output="$1"
    if echo "$output" | grep -qi "rate.limit\|429"; then echo "rate_limit"; return; fi
    if echo "$output" | grep -qi "auth\|unauthorized\|401\|403"; then echo "auth_error"; return; fi
    if echo "$output" | grep -qi "timeout\|timed.out"; then echo "timeout"; return; fi
    echo "service_error"
}

# Claude self-review output parsing
_self_review_is_clean() {
    local output="$1"
    [[ -z "$output" ]] && return 1
    if echo "$output" | grep -qi "no issues\|no findings\|all clear\|LGTM\|no problems found"; then
        return 0
    fi
    # Check if only LOW severity findings
    local high_count
    high_count=$(echo "$output" | grep -ciE '(CRITICAL|HIGH):' 2>/dev/null) || high_count=0
    [[ "$high_count" -eq 0 ]] && return 0
    return 1
}

_count_self_issues() {
    local output="$1"
    local count
    count=$(echo "$output" | grep -ciE '(CRITICAL|HIGH|MEDIUM):' 2>/dev/null) || count=0
    echo "$count"
}
```

---

## 5. Timeout Utility (`autopilot-lib.sh`)

```bash
# _exec_in_new_pgrp COMMAND [ARGS...]
# Replaces current process with COMMAND in a new process group.
# The exec prefix is MANDATORY (Decision #32): without it, bash forks a
# subshell (PID S) then perl/python3 (PID X). $! captures S but setpgrp
# makes X the PGID leader. kill -- -S targets parent's PGID — catastrophic.
# With exec, the subshell IS perl/python3: $! = PGID leader.
#
# Perl primary (4ms startup, ships on all macOS through Tahoe 26).
# Python3 fallback (51ms startup, guaranteed via Xcode CLT / Homebrew prereq).
_exec_in_new_pgrp() {
    if command -v perl >/dev/null 2>&1; then
        exec perl -e 'setpgrp(0,0); exec @ARGV' "$@"
    elif command -v python3 >/dev/null 2>&1; then
        exec python3 -c 'import os,sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
    else
        log ERROR "perl or python3 required for process group isolation"
        return 1
    fi
}

# run_with_timeout SECONDS COMMAND [ARGS...]
# Returns: command exit code, or 124 on timeout
# Requires: bash 4.3+ (wait -n)
#
# IMPORTANT: The command MUST be wrapped with process group isolation
# (e.g., _exec_in_new_pgrp ...) so that kill -- -$pid
# only affects the command's process group, not the parent script.
# Without isolation, kill -- -$pid targets the parent's PGID (catastrophic).
#
# On timeout: SIGTERM → 2s grace → SIGKILL (Decision #28).
# SIGTERM alone can hang forever if the process ignores it (Codex CLI
# issues #7187, #13715, #14048). SIGKILL is uncatchable.
#
# Recovery: wait -n can return 127 if SIGCHLD reaps child before wait -n
# collects it (Decision #30). Explicit wait $PID retrieves cached status.
run_with_timeout() {
    local timeout_secs="$1"
    shift

    "$@" & local cmd_pid=$!
    sleep "$timeout_secs" & local watchdog_pid=$!

    # Wait for whichever finishes first
    wait -n "$cmd_pid" "$watchdog_pid" 2>/dev/null
    local first_status=$?

    # Recovery: wait -n exit 127 race (Decision #30)
    # SIGCHLD may reap child before wait -n collects it → spurious 127.
    # Explicit wait $PID retrieves cached status (POSIX guaranteed).
    # && ... || ... pattern prevents set -e abort on non-zero exit.
    if [[ $first_status -eq 127 ]] && ! kill -0 "$cmd_pid" 2>/dev/null; then
        wait "$cmd_pid" 2>/dev/null && first_status=$? || first_status=$?
    fi

    # Determine which finished
    if kill -0 "$cmd_pid" 2>/dev/null; then
        # Command still running → watchdog fired first → timeout
        kill -- -"$cmd_pid" 2>/dev/null        # SIGTERM to process group
        sleep 2                                 # Grace period for clean shutdown
        if kill -0 "$cmd_pid" 2>/dev/null; then
            kill -9 -- -"$cmd_pid" 2>/dev/null  # SIGKILL (uncatchable)
        fi
        wait "$cmd_pid" 2>/dev/null
        return 124
    else
        # Command finished → kill watchdog
        kill "$watchdog_pid" 2>/dev/null
        wait "$watchdog_pid" 2>/dev/null
        return $first_status
    fi
}
```

---

## 6. New Prompt Functions (`autopilot-prompts.sh`)

### `prompt_self_review()`

```bash
prompt_self_review() {
    local epic_num="$1" title="$2" repo_root="$3" merge_target="$4"

    cat <<PROMPT
You are an adversarial code reviewer. Your job is to find bugs, security issues,
and correctness problems in the code changes for epic ${epic_num}: ${title}.

Review all files changed between origin/${merge_target} and HEAD.
Use \`git diff --name-only origin/${merge_target}..HEAD\` to list changed files,
then Read each file and review thoroughly.

Exclude from review: *.lock, node_modules/*, dist/*, *.gen.*, *.sql.go

For each issue found, report:
- **File**: path
- **Line**: number
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Description**: what's wrong and why

Focus areas (OWASP + correctness):
1. SQL injection, XSS, command injection
2. Authentication/authorization bypasses
3. Input validation gaps
4. Error handling (swallowed errors, missing nil checks)
5. Race conditions, deadlocks
6. Resource leaks (unclosed connections, file handles)
7. Off-by-one errors, boundary conditions
8. Missing test coverage for critical paths
9. Broken imports or dead code from incomplete refactors

If no issues found, say exactly: "No issues found."

Do NOT suggest style improvements, naming changes, or refactors.
Only report actual bugs, security issues, and correctness problems.
PROMPT
}
```

### `prompt_review_fix()`

Parameterized version of existing `prompt_coderabbit_fix()`. Preserves all parameters
including `_preamble()` call (Decision #15) — constitutional context + architecture reading
are non-negotiable. Uses `epic_num` in commit message (matching convention across all
fix-phase prompts: `prompt_security_fix()`, `prompt_finalize_fix()`, etc.).

```bash
prompt_review_fix() {
    local tier="$1" epic_num="$2" title="$3" repo_root="$4" short_name="$5" review_output="$6"

    local tier_label
    case "$tier" in
        cli)    tier_label="CodeRabbit" ;;
        codex)  tier_label="Codex" ;;
        self)   tier_label="Claude adversarial review" ;;
        *)      tier_label="Code review ($tier)" ;;
    esac

    cat <<PROMPT
$(_preamble "$epic_num" "$title" "$repo_root")

${tier_label} has reviewed changes on branch ${short_name} and found potential issues.
Verify each finding against the actual code before acting on it.

${tier_label} REVIEW OUTPUT:
\`\`\`
${review_output}
\`\`\`

Instructions:
1. Read each finding carefully — understand the file and line referenced.
2. Read the relevant source files to verify whether the finding is a real issue.
3. For each finding, decide: is this a genuine bug, security issue, or correctness problem in the actual code?
   - YES (real issue): fix it.
   - NO (false positive, already handled, or trivial style nit): skip it — do not change code for non-issues.
   Skip findings that only affect docs, spec files, or formatting unless they cause runtime problems.
   If findings include severity labels, prioritize CRITICAL/P0 and HIGH/P1; fix MEDIUM/P2 only if straightforward (< 5 lines).
   Focus your effort on the issues that matter most.
4. After fixing, verify:
$(if [[ -n "\$PROJECT_TEST_CMD" ]]; then echo "   cd ${repo_root}/\${PROJECT_WORK_DIR} && \${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "\$PROJECT_LINT_CMD" ]]; then echo "   cd ${repo_root}/\${PROJECT_WORK_DIR} && \${PROJECT_LINT_CMD}"; fi)
5. Commit all fixes:
   git add <specific files>
   git commit -m "fix(${epic_num}): resolve ${tier_label} review findings"
6. Verify clean working tree: git status
PROMPT
}
```

### `prompt_coderabbit_fix()` backward-compat alias

Keep in `autopilot-prompts.sh` through v0.10.0. Delegates to `prompt_review_fix` with `tier="cli"`:

```bash
prompt_coderabbit_fix() {
    prompt_review_fix "cli" "$1" "$2" "$3" "$4" "$5"
}
```

### `prompt_self_review_chunk()`

Scoped variant of `prompt_self_review()` for chunked review of a single directory.
Called from `_tier_claude_self_review_chunked()` (lines 387, 402).

```bash
prompt_self_review_chunk() {
    local epic_num="$1" title="$2" repo_root="$3" merge_target="$4" dir="$5"

    cat <<PROMPT
You are an adversarial code reviewer. Your job is to find bugs, security issues,
and correctness problems in the code changes for epic ${epic_num}: ${title}.

Review ONLY files changed in the \`${dir}\` directory between origin/${merge_target} and HEAD.
Use \`git diff --name-only origin/${merge_target}..HEAD -- ${dir}\` to list changed files,
then Read each file and review thoroughly.

Exclude from review: *.lock, node_modules/*, dist/*, *.gen.*, *.sql.go

For each issue found, report:
- **File**: path
- **Line**: number
- **Severity**: CRITICAL / HIGH / MEDIUM / LOW
- **Description**: what's wrong and why

Focus areas (OWASP + correctness):
1. SQL injection, XSS, command injection
2. Authentication/authorization bypasses
3. Input validation gaps
4. Error handling (swallowed errors, missing nil checks)
5. Race conditions, deadlocks
6. Resource leaks (unclosed connections, file handles)
7. Off-by-one errors, boundary conditions
8. Missing test coverage for critical paths
9. Broken imports or dead code from incomplete refactors

If no issues found, say exactly: "No issues found."

Do NOT suggest style improvements, naming changes, or refactors.
Only report actual bugs, security issues, and correctness problems.
PROMPT
}
```

---

## 7. Phase Configuration (`autopilot.sh`)

Add to the associative arrays:

```bash
# Add new entries INLINE in existing declare -A blocks (Decision #29).
# All entries use external variables ($OPUS/$SONNET) — these resolve correctly
# inside declare -A blocks. Self-references would fail, but none are used.
# Keep existing [coderabbit-fix] entries as-is (actively used at line 293).

# In PHASE_MODEL declare -A block (after line 55, before closing paren):
    [self-review]="$OPUS"
    [review-fix]="$OPUS"
    [rebase-fix]="$OPUS"

# In PHASE_TOOLS declare -A block (after line 76, before closing paren):
    [self-review]="Read,Glob,Grep,Bash"
    [review-fix]="Read,Write,Edit,Bash,Glob,Grep"
    [rebase-fix]="Read,Write,Edit,Bash,Glob,Grep"

# In PHASE_MAX_RETRIES declare -A block (after line 97, before closing paren):
    [self-review]=1
    [review-fix]=3
    [rebase-fix]=3
```

> **Note**: `coderabbit-fix` already exists inline in all three arrays (lines 55, 76, 97) — keep as-is.
> Phase names appear in events.jsonl and log filenames; both names are valid and queryable.
>
> **Note**: Line 400 of `autopilot-coderabbit.sh` (inside `_rebase_and_push()`) must change from
> `invoke_claude "coderabbit-fix"` to `invoke_claude "rebase-fix"`. This separates post-rebase
> test fixes from code-review fixes — different semantics, different phase names, correct dashboard display.

### 7.1. `invoke_claude()` validation guard

Under `set -euo pipefail`, accessing a missing associative array key crashes the script with
"unbound variable" — no graceful error message. This guard catches misconfiguration cleanly.
`[[ -v array[key] ]]` requires bash 4.3+ (aligned with version guard bump in Amendment 2).
Fixes a latent bug in 8 direct-call sites that bypass `run_phase()` validation.

```bash
invoke_claude() {
    local phase="$1"
    local prompt="$2"
    local epic_num="$3"
    local title="${4:-}"

    # Validate phase exists in required arrays (missing key + set -u = crash)
    if [[ ! -v PHASE_MODEL["$phase"] ]] || [[ ! -v PHASE_TOOLS["$phase"] ]]; then
        log ERROR "Unknown phase '$phase' — missing from PHASE_MODEL or PHASE_TOOLS"
        return 1
    fi

    local model="${PHASE_MODEL[$phase]}"
    local tools="${PHASE_TOOLS[$phase]}"
    ...rest unchanged...
}
```

---

## 8. Config Variables

### Backward-compatible variable handling

Following the proven shim pattern from `FORCE_ADVANCE_ON_REVIEW_FAIL` → `_STALL`/`_ERROR` (autopilot-lib.sh:552-556):

```bash
# In load_project_config() or equivalent init:
SKIP_REVIEW="${SKIP_REVIEW:-${SKIP_CODERABBIT:-false}}"
REVIEW_TIER_ORDER="${REVIEW_TIER_ORDER:-}"

# Derive from HAS_CODERABBIT if not explicitly set
if [[ -z "$REVIEW_TIER_ORDER" ]]; then
    local tiers=""
    [[ "${HAS_CODERABBIT:-false}" == "true" ]] && tiers="cli"
    [[ "${HAS_CODEX:-false}" == "true" ]] && tiers="${tiers:+$tiers,}codex"
    # Self-review always available (uses Anthropic API which is already required)
    tiers="${tiers:+$tiers,}self"
    REVIEW_TIER_ORDER="$tiers"
fi
```

### CLI arg update (`autopilot.sh` arg parsing)

```bash
# Keep old flag, add new one (both accepted):
--skip-review|--skip-coderabbit)  SKIP_REVIEW=true ;;
```

Help text update:
```
--skip-review        Skip code review during remote merge (alias: --skip-coderabbit)
```

### `autopilot-detect-project.sh` env template

Add to the env template writing (after line 275):

```bash
# Review tiers
HAS_CODEX="$HAS_CODEX"
CODERABBIT_MAX_ROUNDS=2
# REVIEW_TIER_ORDER=""    # Auto-detected. Override: cli,codex,self
# CODEX_REVIEW_TIMEOUT=300
# CODEX_MAX_DIFF_BYTES=800000

# Per-tier convergence limits (defaults shown)
# CODEX_MAX_ROUNDS=2
# CLAUDE_SELF_REVIEW_MAX_ROUNDS=2

# Deprecated: use SKIP_REVIEW and REVIEW_TIER_ORDER above
# HAS_CODERABBIT="$HAS_CODERABBIT"
```

Add Codex detection (near line 221, alongside CodeRabbit detection):

```bash
HAS_CODEX="false"
command -v codex &>/dev/null && HAS_CODEX="true"
```

> **Note**: JQ availability is guarded inline by `_tier_codex()` (`command -v jq`), matching the existing pattern in `autopilot-design.sh:15`. No standalone `HAS_JQ` variable needed.

### LAST_CR_STATUS

Keep the variable name as-is. 3 read locations in the codebase:
1. `autopilot-coderabbit.sh:116` — emptiness check
2. `autopilot-lib.sh:485` — verbatim markdown embed
3. `autopilot-coderabbit.sh:232` — log output (inside CodeRabbit tier — "CodeRabbit CLI:" label is accurate there)

New tier-specific strings like `"clean (tier: codex)"` display correctly without code changes.
**Label change** (Amendment 4): `echo "**CodeRabbit**: $LAST_CR_STATUS"` → `echo "**Code Review**: $LAST_CR_STATUS"` at autopilot-lib.sh:485. Variable name `LAST_CR_STATUS` unchanged (~25 lines would need renaming for zero benefit). Log message at line 232 stays as "CodeRabbit CLI:" (inside CodeRabbit tier — accurate there).

---

## 9. Event Names

Keep existing event names. Add a `tier` field to new events:

```bash
# New events (additive — no existing events renamed):
_emit_event "$events_log" "review_tier_start" "{\"tier\":\"$tier\"}"
_emit_event "$events_log" "review_tier_end" "{\"tier\":\"$tier\",\"result\":\"clean|issues|error\"}"
_emit_event "$events_log" "review_all_tiers_failed" "{}"
```

Existing `coderabbit_cli_*` events within `_tier_coderabbit_cli()` are unchanged. Historical events.jsonl entries remain valid — no consumer filters on CodeRabbit-specific event names.

---

## 9.5. Managed Section Utility (`common.sh`)

### `update_managed_section()` — new function (Amendment 9)

Marker-based fenced section writer for shared config files (AGENTS.md, etc.). Prevents ownership conflicts between speckit-autopilot and speckit-core.

```bash
# update_managed_section FILEPATH BLOCK_NAME CONTENT
# - If markers exist: replace content between them (awk-based)
# - If markers absent: append new block at end of file
# - If file doesn't exist: create with block
# - Idempotent, safe for concurrent-free manual execution
update_managed_section() {
    local filepath="$1" block_name="$2" content="$3"
    local begin_marker="<!-- BEGIN ${block_name} MANAGED BLOCK -->"
    local end_marker="<!-- END ${block_name} MANAGED BLOCK -->"

    if [[ ! -f "$filepath" ]]; then
        # File doesn't exist — create with block
        printf '%s\n%s\n%s\n' "$begin_marker" "$content" "$end_marker" > "$filepath"
        return
    fi

    if grep -qF "$begin_marker" "$filepath"; then
        # Markers exist — replace content between them
        awk -v begin="$begin_marker" -v end="$end_marker" -v content="$content" '
            $0 == begin { print; print content; skip=1; next }
            $0 == end   { skip=0 }
            !skip       { print }
        ' "$filepath" > "${filepath}.tmp" && mv "${filepath}.tmp" "$filepath"
    else
        # Markers absent — append block at end
        printf '\n%s\n%s\n%s\n' "$begin_marker" "$content" "$end_marker" >> "$filepath"
    fi
}
```

---

## 10. install.sh Changes

### Update copy loop (line 116)

Replace `autopilot-coderabbit.sh autopilot-coderabbit-helpers.sh` with `autopilot-review.sh autopilot-review-helpers.sh autopilot-merge.sh` in the `for script in ...` list.

### Add cleanup after copy loop (after line 123, following existing precedent at lines 149-154)

```bash
# Remove renamed scripts (pre-v0.9.6: coderabbit → review + merge split)
for legacy in autopilot-coderabbit.sh autopilot-coderabbit-helpers.sh; do
    if [[ -f "$DEST/$legacy" ]]; then
        rm -f "$DEST/$legacy"
        info "Cleaned up renamed script: $legacy"
    fi
done
```

**Why AFTER the copy loop**: If the copy loop fails partway through, old files still work. Cleanup only happens after new files are confirmed in place.

**Consumer repo impact**: All 3 consumer repos (Brightwell_Practice, Stageflow.Studio, ADflair) have identical copies to source — zero local modifications. Files are git-tracked, so recovery via `git checkout` if needed.

### Deploy `AGENTS.md` via managed sections (after cleanup block)

```bash
# ── Codex project instructions (marker-based to preserve speckit-core content) ──
source "$DEST/common.sh"
AGENTS_CONTENT=$(cat <<'AGENTS_EOF'
# Codex Review Instructions
## Project Context
Bash orchestrator for AI-powered dev pipelines. All scripts run under set -euo pipefail.
## Intentional Patterns (do NOT flag)
- `|| true` after grep/git — deliberate pipefail protection
- `|| var=0` after grep -c — canonical safe pattern
- `$()` subshells with `|| exit_code=$?` — deliberate error capture
- Global variables (LAST_CR_STATUS, LAST_PR_NUMBER) — shared state between sourced scripts
## Focus Areas
- Bugs, security, correctness — NOT style, naming, comments
AGENTS_EOF
)
update_managed_section "AGENTS.md" "SPECKIT-AUTOPILOT" "$AGENTS_CONTENT"
```

> **Note**: Content deployed via `update_managed_section()` (marker-based fenced section).
> Each tool owns a `<!-- BEGIN TOOL MANAGED BLOCK -->` section. Content outside markers is preserved.
> Teams with custom Codex instructions should use `AGENTS.override.md`.

---

## 11. Test Plan

### New file: `tests/test-review-tiers.sh`

```
Test cases:
├── Tier orchestrator
│   ├── Falls through to next tier on return 2
│   ├── Stops on clean (return 0)
│   ├── Stops on issues (return 1)
│   ├── All tiers fail → applies FORCE_ADVANCE_ON_REVIEW_ERROR
│   ├── All tiers fail without force-advance → returns 1
│   └── Unknown tier name → skips with warning
├── Tier-specific
│   ├── _tier_coderabbit_cli skips when HAS_CODERABBIT=false
│   ├── _tier_codex skips when HAS_CODEX=false
│   ├── _tier_codex respects CODEX_REVIEW_TIMEOUT
│   ├── _tier_codex JSONL parsing extracts agent_message
│   ├── _tier_codex handles empty JSONL gracefully
│   ├── _tier_codex requires jq
│   └── _tier_claude_self_review always available
├── Helpers (tier dispatch)
│   ├── _review_is_clean dispatches by tier
│   ├── _count_review_issues dispatches by tier
│   ├── _classify_review_error dispatches by tier
│   ├── _codex_is_clean: "no issues" → clean
│   ├── _codex_is_clean: P0-P2 markers → not clean
│   ├── _codex_is_clean: no markers + "appears correct" → clean
│   ├── _self_review_is_clean: "No issues found" → clean
│   └── _self_review_is_clean: CRITICAL findings → not clean
├── Convergence loop
│   ├── _review_fix_loop: clean on round 1 → returns 0
│   ├── _review_fix_loop: stall detected → applies FORCE_ADVANCE
│   ├── _review_fix_loop: stall without force-advance → returns 1
│   ├── _review_fix_loop: max_rounds exhausted → applies FORCE_ADVANCE_ON_REVIEW_ERROR
│   ├── _review_fix_loop: max_rounds=2 for self tier
│   ├── _review_fix_loop: tier error during re-review → returns 1
│   └── _review_fix_loop: diminishing returns exit at round 2
├── Config
│   ├── REVIEW_TIER_ORDER parsed correctly
│   ├── Default tier order derived from HAS_CODERABBIT + HAS_CODEX
│   ├── SKIP_REVIEW=true skips all tiers
│   └── SKIP_CODERABBIT backward compat
├── Timeout
│   ├── run_with_timeout: command finishes before timeout
│   ├── run_with_timeout: command exceeds timeout → returns 124
│   └── run_with_timeout: watchdog cleaned up on success
├── Diff size guard
│   ├── Diff under 60K tokens → single review
│   ├── Diff over 60K tokens → chunked review
│   └── Single chunk over 60K → skipped with warning
├── Codex schema + prompt (Amendment 1)
│   ├── codex-review-schema.json is valid JSON Schema
│   ├── _tier_codex builds prompt file with diff appended
│   ├── _tier_codex diff size guard (CODEX_MAX_DIFF_BYTES) → return 2
│   ├── _tier_codex prompt_file cleaned up by trap
│   └── _tier_codex parses -o output (not JSONL)
├── AGENTS.md managed sections (Amendment 9)
│   ├── update_managed_section creates new file with markers
│   ├── update_managed_section updates existing block between markers
│   ├── update_managed_section appends block when markers absent
│   └── update_managed_section preserves content outside markers
└── Parser bug fixes (Amendment 8)
    ├── _count_codex_issues: non-JSON input → 0 (not set -e abort)
    ├── _codex_is_clean: overall_correctness=true + no P0/P1 → clean
    ├── _codex_is_clean: overall_correctness=false → not clean
    ├── _codex_is_clean: overall_correctness=true + P0 findings → not clean (conservative)
    └── _count_self_issues: zero matches → single "0" output (not "0\n0")
```

### Rename: `tests/test-coderabbit-helpers.sh` → `tests/test-review-helpers.sh`

Changes:
- Line 32: source path update
- Remove `_count_pr_issues` tests (lines 110-120) — dead function removed (Amendment 7)
- Add parser bug fix tests (Amendment 8):
  - `_count_codex_issues`: non-JSON input → 0 (not set -e abort)
  - `_codex_is_clean`: null priority findings → not clean
  - `_codex_is_clean`: overall_correctness=true + no P0/P1 → clean
  - `_codex_is_clean`: overall_correctness=false → not clean
  - `_codex_is_clean`: overall_correctness=true + P0 findings → not clean (conservative)
  - `_count_self_issues`: zero matches → single "0" output (not "0\n0")

### Update: `.claude/settings.local.json`

Update test invocation path if referenced.

---

## 11.5. Bash Version Guard (Amendment 2)

Bump version guard in `autopilot.sh` from `< 4` to `< 4.3`:

```bash
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "ERROR: bash 4.3+ required (found $BASH_VERSION). Install via: brew install bash" >&2
    exit 1
fi
```

**Why 4.3**: `wait -n` (introduced in 4.3-alpha) and `[[ -v array[key] ]]` subscript support both require bash 4.3. macOS ships 3.2 (Homebrew gives 5.3.9), Ubuntu 22.04 ships 5.1 — the 4.3 floor is safe for all supported platforms. Only `autopilot.sh` needs the bump (`autopilot-watch.sh` uses no 4.3+ features).

---

## 12. Diff Size Guard (Self-Review)

The self-review tier checks diff size before sending to Claude:

```
Estimate: git diff ... | wc -c → bytes → /4 → tokens

< 60K tokens:  Single review pass (full diff context)
> 60K tokens:  Chunk by first-level directory (backend/, frontend/, renderer/)
> 60K per first-level chunk: Fall back to second-level dirs (backend/internal/api/, etc.)
> 60K per second-level chunk: Skip with warning (likely generated/vendored)
```

First-level chunking keeps cross-cutting context together (e.g., handler changes + validation changes reviewed in the same pass) and minimizes Claude invocations.

Exclude from diff: `*.lock`, `node_modules/`, `dist/`, `*.gen.*`, `*.sql.go`

---

## 13. Codex Project Instructions

**New file**: `AGENTS.md` (~20 lines, at repo root)

Codex reads `AGENTS.md` per its official discovery algorithm. Without project instructions, Codex flags intentional patterns as issues, increasing false positives.

```markdown
# Codex Review Instructions

## Project Context
Bash orchestrator for AI-powered software development pipelines.
All scripts run under `set -euo pipefail`.

## Intentional Patterns (do NOT flag)
- `|| true` after grep/git commands — deliberate pipefail protection
- `|| var=0` after `grep -c` — canonical safe pattern (grep returns 1 on no match)
- `eval` is never used — do not warn about it
- `$()` subshells with `|| exit_code=$?` — deliberate error capture
- `env -u CLAUDECODE claude -p` — required to avoid nested session detection
- Global variables (LAST_CR_STATUS, LAST_PR_NUMBER) — shared state between sourced scripts

## Focus Areas
- Actual bugs: logic errors, off-by-one, missing guards
- Security: command injection via unquoted variables, unsafe temp files
- Correctness: wrong exit codes, missing error paths
- Do NOT flag: style, naming, missing comments, function length
```

This file's content is embedded in the `install.sh` heredoc and deployed via `update_managed_section()` to consumer repo roots. The `<!-- BEGIN SPECKIT-AUTOPILOT MANAGED BLOCK -->` markers ensure speckit-core's agent context content is preserved.

---

## Implementation Order

### Phase 1: Infrastructure (no behavior change)

1. Create `src/autopilot-merge.sh` — extract merge functions from autopilot-coderabbit.sh
2. Create `src/autopilot-review.sh` — extract review function, rename to `_tier_coderabbit_cli()`
3. Rename `src/autopilot-coderabbit-helpers.sh` → `src/autopilot-review-helpers.sh`
4. Remove dead functions during rename: `_cr_pr_review_state()`, `_cr_pr_comments()`, `_count_pr_issues()` (Amendment 7 — zero callers since v0.6.0)
5. Bump bash version guard from `< 4` to `< 4.3` (Amendment 2 — `wait -n` and `[[ -v array[key] ]]` require 4.3)
6. Update `src/autopilot.sh` source lines (line 29 → 3 new source lines)
7. Add `invoke_claude()` validation guard (`[[ -v ]]` check — note bash 4.3 requirement, Amendment 6)
8. Update `install.sh` copy loop + add cleanup
9. Rename test file + remove `_count_pr_issues` tests (dead function)
10. Verify all existing tests pass (behavior unchanged at this point)
11. Commit: `refactor: split coderabbit.sh into review + merge modules`

### Phase 2: Tier framework

1. Add `run_with_timeout()` to `autopilot-lib.sh` (with SIGTERM → 2s grace → SIGKILL process group kill, Decision #28; with `wait -n` exit 127 recovery, Decision #30)
1b. Add `_exec_in_new_pgrp()` to `autopilot-lib.sh` (perl primary + python3 fallback, Decision #32)
2. Add `_tiered_review()` orchestrator to `autopilot-review.sh`
3. Add `_review_fix_loop()` — extracted from current convergence loop with per-tier `max_rounds` parameter
4. Add `prompt_review_fix()` (6 params) and `prompt_coderabbit_fix()` backward-compat alias to `autopilot-prompts.sh`
5. Add tier-aware dispatch functions to `autopilot-review-helpers.sh`
6. Phase arrays — add new entries inline in existing `declare -A` blocks (Decision #29); keep existing `[coderabbit-fix]` entries as-is
7. Summary label change: `**CodeRabbit**` → `**Code Review**` in `autopilot-lib.sh:485` (Amendment 4)
8. Wire `_tiered_review()` into `do_remote_merge()` (replacing direct `_coderabbit_cli_review()` call)
9. Add config variable handling (REVIEW_TIER_ORDER, backward compat shims)
10. Add `--skip-review` alias for `--skip-coderabbit`
11. Add `rebase-fix` phase entries to PHASE_MODEL/PHASE_TOOLS/PHASE_MAX_RETRIES
12. Change line 400 of `autopilot-coderabbit.sh` (`_rebase_and_push()`) from `invoke_claude "coderabbit-fix"` to `invoke_claude "rebase-fix"`
13. Test: verify Tier 1 (CodeRabbit CLI) works identically to current behavior
14. Commit: `feat: add tiered review orchestrator with CR CLI as tier 1`

### Phase 3: Codex tier

1. Add `update_managed_section()` to `src/common.sh` (Amendment 9)
2. Deploy `AGENTS.md` via `update_managed_section` in `install.sh` (Amendment 9 — replaces raw `cp`)
3. Create `src/codex-review-schema.json` — OpenAI Structured Outputs format (Amendment 1)
4. Add Codex detection to `autopilot-detect-project.sh`
5. Add `_tier_codex()` to `autopilot-review.sh` — full redesign (Amendment 1): pre-computed diff via stdin, `--output-schema`, `-o`, diff size guard (`CODEX_MAX_DIFF_BYTES`), trap documentation (Amendment 3), process group isolation
6. Add Codex classifiers with bug fixes to `autopilot-review-helpers.sh` — `overall_correctness` primary check + `|| jq_count=""` guard (Amendment 8, bugs 1+2)
7. Add `codex-review-schema.json` to `install.sh` copy loop
8. Add `CODEX_REVIEW_TIMEOUT` config
9. Add tier 2 tests
10. Commit: `feat: add codex review as tier 2 fallback`

### Phase 4: Claude self-review tier

1. Add `prompt_self_review()` to `autopilot-prompts.sh`
2. Add `prompt_self_review_chunk()` to `autopilot-prompts.sh`
3. Add `_tier_claude_self_review()` to `autopilot-review.sh`
4. Add first-level dir chunking with second-level fallback
5. Add self-review classifiers to `autopilot-review-helpers.sh`
6. Fix `_count_self_issues` double output bug (Amendment 8, bug 3)
7. Add `self-review`, `review-fix`, and `coderabbit-fix` (independent entry) phase config to `autopilot.sh`
8. Add diff size guard (60K token threshold)
9. Add tier 3 tests
10. Commit: `feat: add claude self-review as tier 3 fallback`

### Phase 5: Finalize

1. Update README bash prerequisite from "bash 4+" to "bash 4.3+" (Amendment 2)
2. Update env template in `autopilot-detect-project.sh`
3. Bump `VERSION` to `0.9.6`
4. Update `--help` output
5. Final test pass (all tiers + fallback + timeout + backward compat)
6. Commit: `chore: bump to v0.9.6 with 3-tier review fallback`

---

## Resolved Questions

All questions from v1.0 have been resolved:

| # | Question | Resolution |
|---|----------|------------|
| 1 | Codex exit codes | **Use output-based detection, not exit codes.** Codex CLI doesn't document exit codes; AI tool exit codes are unreliable. Non-zero = process error (tier fallthrough). Clean/issues determined by parsing output via `_codex_is_clean()` — same proven pattern as CodeRabbit CLI. |
| 2 | Codex auth | **Confirmed authenticated.** API key + OAuth tokens in `~/.codex/auth.json`. Model: gpt-5.2. No action needed. |
| 3 | Chunking granularity | **First-level dirs** (`backend/`, `frontend/`, `renderer/`). Fewer Claude invocations; first-level dirs are already well-scoped; reviewers need cross-cutting context. Falls back to second-level only if a first-level chunk exceeds 60K tokens. |
| 4 | Cost tracking | **Skip.** Codex costs are external (OpenAI billing). Only Claude tiers go through `invoke_claude` which already tracks cost. Not worth the complexity. |
| 5 | Codex project instructions | **Yes, create `AGENTS.md` at repo root.** Codex reads `AGENTS.md` per official discovery algorithm (not `.codex/instructions.md`). ~20 lines: project conventions, intentional patterns (`\|\| true`, `env -u CLAUDECODE`), focus areas. Deployed via `install.sh`. Teams use `AGENTS.override.md` for custom instructions. |
| 6 | `prompt_review_fix` parameter count | **6 parameters** (tier, epic_num, title, repo_root, short_name, review_output). Must preserve `_preamble()` call and `epic_num` in commit message to match convention across all fix-phase prompts. `prompt_coderabbit_fix()` kept as backward-compat alias through v0.10.0. |
| 7 | `prompt_self_review_chunk` definition | **Defined.** Scoped variant of `prompt_self_review()` for chunked directory review. Parameters: epic_num, title, repo_root, merge_target, dir. |
| 8 | Codex CLI invocation syntax | `codex exec --output-schema schema.json -o "$tmpfile" - < "$prompt_file"`. Pre-compute diff (sandbox issue #6688). `--output-schema` viable (bug #4181 fixed). Eliminates JSONL parsing. |
| 9 | Convergence loop per-tier rounds | **`max_rounds` as parameter.** Passed from `_tiered_review()` to `_review_fix_loop()`: CLI=3, Codex=3, Claude=2. Inner retry stays in tier functions. Re-review calls tier function directly (idempotent). |
| 10 | `ensure_coderabbit_config` placement | Place AFTER `HAS_CODERABBIT` check inside `_tier_coderabbit_cli()`. Don't create config when CLI not installed. |
| 11 | Process group isolation | `perl -e 'setpgrp(0,0); exec @ARGV'` + `kill -- -$pid`. `set -m` inside `bash -c` does NOT work (doesn't make shell a group leader). |
| 12 | Temp file cleanup | `trap ERR RETURN` (not just RETURN). RETURN trap does NOT fire on `set -e` abort. Must unset with `trap -` before returning (global scope). |
| 13 | Codex output format | Structured JSON via `--output-schema` (primary). grep-fallback kept for robustness when schema silently dropped. |
| 14 | `invoke_claude` missing phase | `set -u` crashes on missing associative array key. `[[ -v ]]` guard catches gracefully. Fixes latent bug. |
| 15 | AGENTS.md ownership | Marker-based fenced sections via `update_managed_section()` in common.sh. Each tool owns a `<!-- BEGIN TOOL MANAGED BLOCK -->` section. speckit-core's `update-agent-context.sh` content preserved. |
| 16 | Bash `declare -A` aliases | ~~Independent entries required.~~ Superseded: only self-references fail inside `declare -A` blocks. External variables (`$OPUS`) resolve correctly. New entries go inline. See Decision #29. |
| 17 | SIGKILL escalation in `run_with_timeout` | **Required.** SIGTERM alone can hang forever if process ignores it. Codex CLI has multiple open hanging issues (#7187, #13715, #14048). Add 2s grace period after SIGTERM, then SIGKILL to process group. See Decision #28. |
| 18 | `wait -n` exit 127 under `set -e` | Recovery `wait "$cmd_pid"` could abort function under `set -e` if command exited non-zero. Use `&& first_status=$? \|\| first_status=$?` pattern — captures status regardless of success/failure without triggering `set -e`. Currently safe because `_tier_codex` calls `run_with_timeout ... \|\| rc=$?` (suppresses `set -e`), but the pattern must be defensive for future callers. |
| 19 | Subshell `trap EXIT` for `_tier_codex` | Rejected. Three issues: (a) `TIER_OUTPUT=$(...)` under `set -e` aborts parent before `rc=$?`; (b) 5 distinct non-zero exit paths collapse to 1; (c) background process orphaning on subshell kill. Guard-variable pattern preserves all existing behavior. |
| 20 | `_exec_in_new_pgrp` must use `exec` | Without `exec`, bash forks subshell (PID S) → perl (PID X). `$!`=S ≠ PGID leader X. `kill -- -S` targets wrong group. Empirically verified: only `exec perl`/`exec python3` produces correct `$!`=PGID invariant. |
