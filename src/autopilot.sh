#!/usr/bin/env bash
# autopilot.sh — Deterministic shell-based orchestrator for the Spec Kit lifecycle.
#
# Replaces the unreliable single-session /autopilot Claude Code command with a
# bash state machine. Each phase gets a fresh `claude -p` invocation with full
# context window. Loops across epics automatically.
#
# Usage:
#   ./autopilot.sh [epic-number] [--no-auto-continue] [--dry-run]
#
# Examples:
#   ./autopilot.sh              # Auto-detect next epic, live dashboard
#   ./autopilot.sh 003          # Start/resume epic 003
#   ./autopilot.sh --silent     # Suppress live dashboard output
#   ./autopilot.sh --no-auto-continue   # Pause between epics

if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: bash 4+ required (found $BASH_VERSION). Install via: brew install bash" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/autopilot-lib.sh"
source "$SCRIPT_DIR/autopilot-stream.sh"
source "$SCRIPT_DIR/autopilot-prompts.sh"
source "$SCRIPT_DIR/autopilot-github.sh"
source "$SCRIPT_DIR/autopilot-coderabbit.sh"
source "$SCRIPT_DIR/autopilot-verify.sh"
source "$SCRIPT_DIR/autopilot-finalize.sh"
source "$SCRIPT_DIR/autopilot-validate.sh"
source "$SCRIPT_DIR/autopilot-design.sh"

# ─── Configuration ───────────────────────────────────────────────────────────

OPUS="opus"
SONNET="sonnet"

# Phase → model mapping
declare -A PHASE_MODEL=(
    [specify]="$OPUS"
    [clarify]="$OPUS"
    [clarify-verify]="$OPUS"
    [plan]="$OPUS"
    [design-read]="$SONNET"
    [tasks]="$OPUS"
    [analyze]="$OPUS"
    [analyze-verify]="$OPUS"
    [implement]="$SONNET"
    [review]="$OPUS"
    [crystallize]="$OPUS"
    [finalize-fix]="$OPUS"
    [finalize-review]="$OPUS"
    [coderabbit-fix]="$OPUS"
    [conflict-resolve]="$OPUS"
    [security-review]="$OPUS"
    [security-fix]="$OPUS"
)

# Phase → allowed tools
declare -A PHASE_TOOLS=(
    [specify]="Skill,Read,Write,Edit,Bash,Glob,Grep,TodoWrite"
    [clarify]="Skill,Read,Write,Edit,Bash,Glob,Grep"
    [clarify-verify]="Read,Write,Edit,Bash,Glob,Grep"
    [plan]="Skill,Read,Write,Edit,Bash,Glob,Grep,WebSearch,WebFetch"
    [design-read]="Read,Write,Glob,Grep"
    [tasks]="Skill,Read,Write,Edit,Glob,Grep"
    [analyze]="Skill,Read,Write,Edit,Bash,Glob,Grep"
    [analyze-verify]="Skill,Read,Write,Edit,Bash,Glob,Grep"
    [implement]="Skill,Task,Read,Write,Edit,Bash,Glob,Grep,TodoWrite"
    [review]="Read,Write,Edit,Bash,Glob,Grep"
    [crystallize]="Read,Write,Edit,Bash,Glob,Grep"
    [finalize-fix]="Read,Write,Edit,Bash,Glob,Grep"
    [finalize-review]="Read,Write,Edit,Bash,Glob,Grep"
    [coderabbit-fix]="Read,Write,Edit,Bash,Glob,Grep"
    [conflict-resolve]="Read,Write,Edit,Bash,Glob,Grep"
    [security-review]="Read,Write,Glob,Grep"
    [security-fix]="Read,Write,Edit,Bash,Glob,Grep"
)

# Phase → max retries (convergence phases get more attempts)
declare -A PHASE_MAX_RETRIES=(
    [specify]=3
    [clarify]=5
    [clarify-verify]=2
    [plan]=3
    [design-read]=2
    [tasks]=3
    [analyze]=5
    [analyze-verify]=5
    [implement]=3
    [review]=3
    [crystallize]=1
    [finalize-fix]=3
    [finalize-review]=1
    [coderabbit-fix]=3
    [conflict-resolve]=3
    [security-review]=1
    [security-fix]=1
)

# ─── Argument Parsing ────────────────────────────────────────────────────────

TARGET_EPIC=""
TARGET_EPICS=()   # Array of epic numbers when range is specified
AUTO_CONTINUE=true
DRY_RUN=false
SILENT=false
NO_GITHUB=false
GITHUB_RESYNC=false
STRICT_DEPS=false
ALLOW_DEFERRED=false
SKIP_CODERABBIT=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-auto-continue) AUTO_CONTINUE=false ;;
            --dry-run)          DRY_RUN=true ;;
            --silent)           SILENT=true ;;
            --no-github)        NO_GITHUB=true ;;
            --github-resync)    GITHUB_RESYNC=true ;;
            --skip)
                shift
                local skip_phase="$1"
                case "$skip_phase" in
                    clarify|clarify-verify|design-read|analyze) ;;
                    *) echo "ERROR: Cannot skip phase '$skip_phase'. Allowed: clarify, clarify-verify, design-read, analyze" >&2; exit 1 ;;
                esac
                PHASE_MAX_RETRIES[$skip_phase]=0
                ;;
            --fast)
                PHASE_MAX_RETRIES[clarify]=1
                PHASE_MAX_RETRIES[analyze]=1
                ;;
            --strict-deps)      STRICT_DEPS=true ;;
            --allow-deferred)   ALLOW_DEFERRED=true ;;
            --skip-coderabbit)  SKIP_CODERABBIT=true ;;
            --help|-h)
                echo "Usage: autopilot.sh [epic-number] [--no-auto-continue] [--dry-run] [--silent]"
                echo ""
                echo "Options:"
                echo "  epic-number          Target a specific epic (e.g., 003) or range (e.g., 003-007)"
                echo "  --no-auto-continue   Pause between epics instead of auto-continuing"
                echo "  --dry-run            Show what would happen without invoking claude"
                echo "  --silent             Suppress live dashboard output (files still written)"
                echo "  --skip PHASE    Skip a convergence phase (clarify, clarify-verify, design-read, analyze)"
                echo "  --fast          Reduce convergence phases to 1 attempt (faster iteration)"
                echo "  --no-github          Disable GitHub Projects sync"
                echo "  --github-resync      Resync all epics to GitHub Projects and exit"
                echo "  --strict-deps        Block on unmerged dependencies (default: warn only)"
                echo "  --allow-deferred     Defer stuck implement tasks instead of stopping"
                echo "  --skip-coderabbit    Skip CodeRabbit CLI review during remote merge"
                exit 0
                ;;
            [0-9][0-9][0-9]-[0-9][0-9][0-9])
                local range_min="${1%%-*}"
                local range_max="${1##*-}"
                if [[ 10#$range_min -gt 10#$range_max ]]; then
                    echo "Invalid range: $range_min > $range_max" >&2
                    exit 1
                fi
                TARGET_EPICS=()
                for ((i=10#$range_min; i<=10#$range_max; i++)); do
                    TARGET_EPICS+=("$(printf '%03d' "$i")")
                done
                ;;
            [0-9][0-9][0-9])    TARGET_EPIC="$1" ;;
            *)
                echo "Unknown argument: $1" >&2
                exit 1
                ;;
        esac
        shift
    done
}

# ─── Claude Invocation ───────────────────────────────────────────────────────

# Invoke claude -p with the given prompt, model, and allowed tools.
# Uses --output-format stream-json --verbose for structured observability.
# Returns: claude's exit code.
invoke_claude() {
    local phase="$1"
    local prompt="$2"
    local epic_num="$3"
    local title="${4:-}"
    local model="${PHASE_MODEL[$phase]}"
    local tools="${PHASE_TOOLS[$phase]}"

    log PHASE "Running phase: $phase (model=$model)"

    if $DRY_RUN; then
        log INFO "[DRY RUN] Would invoke claude -p with model=$model, tools=$tools"
        log INFO "[DRY RUN] Prompt (first 200 chars): ${prompt:0:200}..."
        return 0
    fi

    # Write prompt to temp file to bypass ARG_MAX / large-stdin bugs
    local prompt_file
    prompt_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-prompt-XXXXXX")
    [[ -z "$prompt_file" || ! -f "$prompt_file" ]] && { log ERROR "Failed to create temp file"; return 1; }
    printf '%s' "$prompt" > "$prompt_file"

    # Print live dashboard header
    _print_dashboard_header "$epic_num" "$title" "$phase" "$model"

    # Export REPO_ROOT for process_stream; SILENT and PHASE_MODEL are already global
    export REPO_ROOT

    local exit_code=0
    env -u CLAUDECODE claude -p "Read the file ${prompt_file} and follow ALL instructions within it exactly." \
        --model "$model" \
        --allowedTools "$tools" \
        --output-format stream-json \
        --verbose \
        --dangerously-skip-permissions \
        2>&1 | process_stream "$epic_num" "$phase" || exit_code=$?

    # Clean up prompt temp file
    rm -f "$prompt_file"

    return "$exit_code"
}

# ─── Phase Dispatch ──────────────────────────────────────────────────────────

# Run a single phase. Returns 0 on success, 1 on failure.
run_phase() {
    local phase="$1"
    local epic_num="$2"
    local short_name="$3"
    local title="$4"
    local epic_file="$5"
    local repo_root="$6"
    local spec_dir="$repo_root/specs/$short_name"

    local prompt=""

    case "$phase" in
        specify)
            prompt="$(prompt_specify "$epic_num" "$title" "$epic_file" "$repo_root")"
            ;;
        clarify)
            prompt="$(prompt_clarify "$epic_num" "$title" "$epic_file" "$repo_root" "$spec_dir")"
            ;;
        clarify-verify)
            prompt="$(prompt_clarify_verify "$epic_num" "$title" "$repo_root" "$spec_dir")"
            ;;
        plan)
            prompt="$(prompt_plan "$epic_num" "$title" "$repo_root")"
            ;;
        design-read)
            local pen_file pen_structure
            pen_file="$(find_pen_file "$repo_root" "$epic_num")"
            if [[ -z "$pen_file" ]]; then
                log WARN "design-read: no .pen file found — skipping"
                return 0
            fi
            log INFO "design-read: pre-extracting .pen structure via jq"
            pen_structure="$(extract_pen_structure "$pen_file")"
            prompt="$(prompt_design_read "$epic_num" "$title" "$repo_root" "$spec_dir" "$pen_file" "$pen_structure")"
            ;;
        tasks)
            prompt="$(prompt_tasks "$epic_num" "$title" "$repo_root")"
            ;;
        analyze)
            prompt="$(prompt_analyze "$epic_num" "$title" "$repo_root" "$spec_dir")"
            ;;
        analyze-verify)
            prompt="$(prompt_analyze_verify "$epic_num" "$title" "$repo_root" "$spec_dir")"
            ;;
        implement)
            prompt="$(prompt_implement "$epic_num" "$title" "$repo_root" "$spec_dir")"
            ;;
        review)
            prompt="$(prompt_review "$epic_num" "$title" "$repo_root" "$short_name")"
            # Conditional deferred-awareness injection
            local _review_deferred_count
            _review_deferred_count=$(grep -c '^\- \[-\]' "$spec_dir/tasks.md" 2>/dev/null) || _review_deferred_count=0
            if [[ "$_review_deferred_count" -gt 0 ]]; then
                prompt+=$'\n\n'"IMPORTANT: ${_review_deferred_count} tasks in tasks.md are marked - [-] (deferred). These were NOT implemented. Verify deferred tasks don't leave security holes, broken imports, or dead code paths. Note deferred scope in your review summary."
            fi
            ;;
        crystallize)
            prompt="$(prompt_crystallize "$epic_num" "$title" "$repo_root" "$short_name")"
            ;;
        *)
            log ERROR "Unknown phase: $phase"
            return 1
            ;;
    esac

    invoke_claude "$phase" "$prompt" "$epic_num" "$title"
}

# ─── Merge ───────────────────────────────────────────────────────────────────

do_merge() {
    local repo_root="$1"
    local epic_num="$2"
    local short_name="$3"
    local title="$4"
    local epic_file="${5:-}"

    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  Epic $epic_num: $title — READY TO MERGE${RESET}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo ""

    # Show summary
    local files_changed
    files_changed=$(git -C "$repo_root" diff --name-only "$MERGE_TARGET"..HEAD | wc -l)
    echo -e "  Files changed: ${BOLD}$files_changed${RESET}"

    if [[ -n "$PROJECT_TEST_CMD" ]]; then
        local test_output
        test_output=$(cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_TEST_CMD" 2>&1 | tail -1 || true)
        echo -e "  Tests: ${BOLD}$test_output${RESET}"
    fi

    echo ""

    # If running non-interactively (no TTY on stdin), auto-merge
    if [[ ! -t 0 ]]; then
        log INFO "Non-interactive mode — auto-merging $short_name to $MERGE_TARGET"
    else
        echo -n "Merge $short_name to $MERGE_TARGET? [Y/n] "
        read -r confirm
        if [[ "$confirm" =~ ^[Nn] ]]; then
            log WARN "Merge declined by user"
            return 1
        fi
    fi

    # Ensure working tree is clean before switching branches
    if ! git -C "$repo_root" diff --quiet 2>/dev/null || \
       ! git -C "$repo_root" diff --cached --quiet 2>/dev/null; then
        log WARN "Uncommitted changes — committing before merge"
        git -C "$repo_root" add -A
        git -C "$repo_root" commit -m "chore(${epic_num}): commit remaining changes before merge"
    fi

    # Verify tests pass before merging
    if [[ -n "${PROJECT_TEST_CMD:-}" ]]; then
        if ! verify_tests "$repo_root"; then
            log ERROR "Tests failing on feature branch — cannot merge"
            return 1
        fi
        log OK "Tests pass — proceeding with merge"
    fi

    if [[ -n "${PROJECT_BUILD_CMD:-}" ]]; then
        if ! verify_build "$repo_root"; then
            log ERROR "Build failed — aborting merge"
            log ERROR "Output: $LAST_BUILD_OUTPUT"
            return 1
        fi
    fi

    if [[ -n "${PROJECT_LINT_CMD:-}" ]]; then
        if ! verify_lint "$repo_root"; then
            log WARN "Lint issues detected — proceeding with merge (non-blocking)"
        fi
    fi

    log INFO "Merging $short_name to $MERGE_TARGET"
    git -C "$repo_root" checkout "$MERGE_TARGET" || {
        log ERROR "Failed to checkout $MERGE_TARGET"
        return 1
    }

    # Verify we actually switched
    local current_branch
    current_branch=$(git -C "$repo_root" branch --show-current)
    if [[ "$current_branch" != "$MERGE_TARGET" ]]; then
        log ERROR "Still on $current_branch after checkout — aborting merge"
        return 1
    fi

    if [[ "${MERGE_STRATEGY:-merge}" == "squash" ]]; then
        git -C "$repo_root" merge --squash "$short_name" || {
            log ERROR "Squash merge failed for $short_name"
            return 1
        }
        git -C "$repo_root" commit -m "feat($epic_num): $title" || {
            log ERROR "Squash commit failed for $short_name"
            return 1
        }
    else
        git -C "$repo_root" merge "$short_name" --no-ff \
            -m "merge: $short_name — $title" || {
            log ERROR "Merge failed for $short_name"
            return 1
        }
    fi
    log OK "Merged $short_name to $MERGE_TARGET"

    gh_sync_done "$repo_root" "$epic_num" "$repo_root/specs/$short_name/tasks.md" || \
        log WARN "GitHub sync-done failed — continuing"

    # Auto-update epic YAML frontmatter
    if [[ -n "$epic_file" ]] && [[ -f "$epic_file" ]]; then
        mark_epic_merged "$epic_file" "$short_name"
        git -C "$repo_root" add "$epic_file"
        git -C "$repo_root" commit -m "fix($epic_num): mark epic YAML as merged"
    fi

    return 0
}

# ─── Cost Accumulation ──────────────────────────────────────────────────

# Read latest phase cost from status file and add to epic_total_cost.
# epic_total_cost is a local in run_epic() — uses nameref-style accumulation.
_accumulate_phase_cost() {
    local repo_root="$1"
    local status_file="$repo_root/.specify/logs/autopilot-status.json"
    if [[ -f "$status_file" ]]; then
        local phase_cost
        phase_cost=$(jq -r '.cost_usd // 0' "$status_file" 2>/dev/null || echo 0)
        epic_total_cost=$(echo "$epic_total_cost $phase_cost" | awk '{printf "%.6f", $1 + $2}')
        log INFO "Epic cumulative cost: \$$epic_total_cost"
    fi
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
        local fix_prompt
        fix_prompt="$(prompt_security_fix "$epic_num" "$title" "$repo_root" "$short_name" "$latest_findings")"
        invoke_claude "security-fix" "$fix_prompt" "$epic_num" "$title" || {
            log WARN "Security fix invocation failed"
        }
        _accumulate_phase_cost "$repo_root"
    done

    # 6. Write marker (orchestrator responsibility — NEVER the model)
    if [[ -f "$tasks_file" ]]; then
        if [[ "$verdict" != "PASS" ]] && [[ $round -ge $max_rounds ]]; then
            log WARN "Security gate: issues remain after $max_rounds rounds — force-advancing"
            echo "" >> "$tasks_file"
            echo "<!-- SECURITY_REVIEWED -->" >> "$tasks_file"
            echo "<!-- SECURITY_FORCE_SKIPPED -->" >> "$tasks_file"
            (cd "$repo_root" && git add "$tasks_file" "$findings_file" && \
             git commit -m "security-review(${epic_num}): force-skipped after ${max_rounds} rounds" 2>/dev/null || true)
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

# ─── Prefix Self-Healing ───────────────────────────────────────────────────

# Rename branch + specs dir when the numeric prefix doesn't match the epic number.
# Usage: _correct_prefix repo_root epic_num wrong_name
# Outputs the corrected name on stdout. No-op if prefix already matches.
_correct_prefix() {
    local repo_root="$1" epic_num="$2" branch_name="$3"
    local expected_prefix="${epic_num}-"

    # Already correct — pass through
    if [[ "$branch_name" =~ ^${expected_prefix} ]]; then
        echo "$branch_name"
        return 0
    fi

    # Extract suffix (everything after first dash)
    local suffix="${branch_name#*-}"
    if [[ -z "$suffix" || "$suffix" == "$branch_name" ]]; then
        log ERROR "Cannot correct prefix: branch '$branch_name' has no valid suffix"
        echo "$branch_name"
        return 1
    fi

    local correct_name="${epic_num}-${suffix}"
    log WARN "Prefix mismatch: '${branch_name}' but epic requires '${expected_prefix}*' — renaming to '${correct_name}'"

    # 1. Rename specs directory (if it exists)
    if [[ -d "$repo_root/specs/$branch_name" ]]; then
        if [[ -d "$repo_root/specs/$correct_name" ]]; then
            log WARN "Target dir specs/$correct_name already exists — removing stale copy"
            rm -rf "$repo_root/specs/$correct_name"
        fi
        mv "$repo_root/specs/$branch_name" "$repo_root/specs/$correct_name"
        log INFO "Renamed specs dir: $branch_name → $correct_name"
    fi

    # 2. Rename git branch
    local current_branch
    current_branch=$(git -C "$repo_root" branch --show-current 2>/dev/null || echo "")
    if [[ "$current_branch" == "$branch_name" ]] || git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        # Remove destination branch if it exists (stale from previous failed run)
        if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$correct_name" 2>/dev/null; then
            if [[ "$current_branch" == "$correct_name" ]]; then
                log WARN "Already on $correct_name — skipping branch rename"
            else
                log WARN "Target branch $correct_name already exists — deleting stale branch"
                git -C "$repo_root" branch -D "$correct_name" >/dev/null 2>&1 || true
            fi
        fi
        git -C "$repo_root" branch -m "$branch_name" "$correct_name" >/dev/null 2>&1 || true
        log INFO "Renamed branch: $branch_name → $correct_name"
    fi

    # 3. Commit only the rename (explicit paths, not -A)
    git -C "$repo_root" add "specs/$correct_name" >/dev/null 2>&1 || true
    git -C "$repo_root" rm -r --cached "specs/$branch_name" >/dev/null 2>&1 || true
    git -C "$repo_root" commit -m "chore(${epic_num}): fix feature prefix ${branch_name} → ${correct_name}" --allow-empty >/dev/null 2>&1 || true

    echo "$correct_name"
    return 0
}

# ─── Main Epic Loop ─────────────────────────────────────────────────────────

run_epic() {
    local repo_root="$1"
    local epic_num="$2"
    local short_name="$3"
    local title="$4"
    local epic_file="$5"
    local epic_total_cost=0

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║  Epic $epic_num: $title${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Eager status write so watch dashboard picks up the new epic immediately
    local _status_file="$repo_root/.specify/logs/autopilot-status.json"
    mkdir -p "$(dirname "$_status_file")"
    jq -nc \
        --arg e "$epic_num" \
        --arg p "initializing" \
        --arg m "" \
        --arg t "$title" \
        '{epic:$e, phase:$p, model:$m, title:$t, cost_usd:0, tokens_in:0, tokens_out:0, iteration:0}' \
        > "$_status_file"

    # Correct prefix before state detection (self-healing)
    if [[ -n "$short_name" ]]; then
        short_name="$(_correct_prefix "$repo_root" "$epic_num" "$short_name")"
    fi

    # ── Pre-flight epic validation ──
    # Only validate on early states — no point re-validating at implement/review
    local _pre_state
    _pre_state="$(detect_state "$repo_root" "$epic_num" "$short_name")"
    if [[ -n "$epic_file" ]] && [[ -f "$epic_file" ]]; then
        case "$_pre_state" in
            specify|clarify|clarify-verify|plan|design-read|tasks)
                if ! validate_epic "$repo_root" "$epic_num" "$epic_file"; then
                    log ERROR "Epic $epic_num failed validation — fix the epic file and re-run"
                    return 1
                fi
                ;;
            *)
                log INFO "Skipping validation — epic already at $_pre_state"
                ;;
        esac
    fi

    # Ensure correct branch (skip for specify — it creates the branch)
    local state
    state="$(detect_state "$repo_root" "$epic_num" "$short_name")"

    if [[ "$state" != "specify" ]] && [[ -n "$short_name" ]]; then
        ensure_feature_branch "$repo_root" "$short_name"
    fi

    # Phase loop
    local total_iterations=0
    local MAX_TOTAL_ITERATIONS=30
    local consecutive_deferred=0

    while true; do
        total_iterations=$((total_iterations + 1))
        if [[ $total_iterations -gt $MAX_TOTAL_ITERATIONS ]]; then
            log ERROR "Epic $epic_num exceeded $MAX_TOTAL_ITERATIONS total phase iterations — possible oscillation. Stopping."
            log ERROR "Resume with: ./autopilot.sh $epic_num"
            return 1
        fi

        state="$(detect_state "$repo_root" "$epic_num" "$short_name")"
        log INFO "Detected state: $state"

        local _tasks_file=""
        [[ -n "$short_name" ]] && _tasks_file="$repo_root/specs/$short_name/tasks.md"
        gh_sync_phase "$repo_root" "$epic_num" "$state" "$_tasks_file"

        if [[ "$state" == "done" ]]; then
            log OK "Epic $epic_num is complete and merged"
            return 0
        fi

        if [[ "$state" == "security-review" ]]; then
            _run_security_gate "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"
            continue  # re-detect state → should now be "review"
        fi

        if [[ "$state" == "review" ]]; then
            # Review first, then merge
            local retries=0
            while [[ $retries -lt ${PHASE_MAX_RETRIES[$state]:-3} ]]; do
                if run_phase "review" "$epic_num" "$short_name" "$title" "$epic_file" "$repo_root"; then
                    _accumulate_phase_cost "$repo_root"
                    break
                fi
                _accumulate_phase_cost "$repo_root"
                retries=$((retries + 1))
                log WARN "Review attempt $retries/${PHASE_MAX_RETRIES[$state]:-3} failed, retrying..."
            done

            if [[ $retries -ge ${PHASE_MAX_RETRIES[$state]:-3} ]]; then
                log ERROR "Review failed after ${PHASE_MAX_RETRIES[$state]:-3} attempts"
                return 1
            fi

            log INFO "Review phase complete — transitioning to merge gate"
            log INFO "Current branch: $(git -C "$repo_root" branch --show-current 2>/dev/null || echo 'unknown')"
            log INFO "Working tree clean: $(git -C "$repo_root" status --porcelain 2>/dev/null | wc -l | tr -d ' ') uncommitted files"

            # Merge gate

            # Safety push: ensure branch exists on remote before entering merge gate
            local current_branch
            current_branch=$(git -C "$repo_root" branch --show-current 2>/dev/null || echo "")
            if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
                log INFO "Safety push: pushing $current_branch to remote before merge gate"
                local push_err
                if ! push_err=$(git -C "$repo_root" push -u origin "$current_branch" --no-verify 2>&1); then
                    log WARN "Safety push failed: $push_err — continuing anyway"
                fi
            fi
            log INFO "Entering merge gate for epic $epic_num ($short_name)"
            if ! do_remote_merge "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"; then
                return 1
            fi
            log OK "Merge gate passed for epic $epic_num"

            # Post-merge crystallization — update context files on base branch
            # Non-blocking: failure does not stop the pipeline
            if ! run_phase "crystallize" "$epic_num" "$short_name" "$title" "$epic_file" "$repo_root"; then
                log WARN "Crystallize phase failed — continuing (non-blocking)"
            fi
            _accumulate_phase_cost "$repo_root"

            # Write post-epic summary
            write_epic_summary "$repo_root" "$epic_num" "$short_name" "$title" "$epic_total_cost"
            return 0
        fi

        # Run the phase with retry logic
        local retries=0
        local prev_state="$state"

        while [[ $retries -lt ${PHASE_MAX_RETRIES[$state]:-3} ]]; do
            local phase_exit=0
            run_phase "$state" "$epic_num" "$short_name" "$title" "$epic_file" "$repo_root" || phase_exit=$?
            # Always accumulate cost after every phase attempt (success or failure)
            _accumulate_phase_cost "$repo_root"
            if [[ $phase_exit -eq 0 ]]; then
                # After specify, refresh short_name from actual git branch.
                # create-new-feature.sh may use a different prefix (e.g. 036-)
                # than the epic number (e.g. 012-), causing a mismatch.
                if [[ "$state" == "specify" ]]; then
                    local actual_branch
                    actual_branch=$(git -C "$repo_root" branch --show-current 2>/dev/null || echo "")
                    if [[ -n "$actual_branch" ]] && [[ "$actual_branch" != "$BASE_BRANCH" ]] && [[ "$actual_branch" != "$short_name" ]]; then
                        log INFO "Branch mismatch: YAML=$short_name, actual=$actual_branch — correcting"
                        # Correct prefix if it doesn't match the epic number
                        actual_branch="$(_correct_prefix "$repo_root" "$epic_num" "$actual_branch")"
                        short_name="$actual_branch"
                        if [[ -n "$epic_file" ]] && [[ -f "$epic_file" ]]; then
                            sed "s/^branch:.*/branch: $short_name/" "$epic_file" > "${epic_file}.tmp" && mv "${epic_file}.tmp" "$epic_file"
                            log INFO "Updated $(basename "$epic_file"): branch=$short_name"
                        fi
                    elif [[ -z "$short_name" ]]; then
                        # No branch in YAML — scan for newly created spec dir
                        local _found=false
                        if [[ -n "$actual_branch" ]] && [[ "$actual_branch" != "$BASE_BRANCH" ]]; then
                            short_name="$actual_branch"
                            _found=true
                        else
                            for dir in "$repo_root/specs/${epic_num}"-*; do
                                if [[ -d "$dir" ]]; then
                                    short_name="$(basename "$dir")"
                                    _found=true
                                    break
                                fi
                            done
                        fi
                        if $_found || [[ -n "$short_name" ]]; then
                            # Correct prefix before using the name
                            short_name="$(_correct_prefix "$repo_root" "$epic_num" "$short_name")"
                            log INFO "Spec dir created: $short_name"
                            ensure_feature_branch "$repo_root" "$short_name"
                            if [[ -n "$epic_file" ]] && [[ -f "$epic_file" ]]; then
                                sed "s/^branch:.*/branch: $short_name/" "$epic_file" > "${epic_file}.tmp" && mv "${epic_file}.tmp" "$epic_file"
                                log INFO "Updated $(basename "$epic_file"): branch=$short_name"
                            fi
                        fi
                    fi
                fi

                # Verify state advanced
                local new_state
                new_state="$(detect_state "$repo_root" "$epic_num" "$short_name")"

                if [[ "$new_state" != "$prev_state" ]]; then
                    log OK "Phase $prev_state → $new_state (exit=$phase_exit)"
                    consecutive_deferred=0  # Reset on successful phase transition

                    # After tasks phase: create task issues
                    if [[ "$prev_state" == "tasks" ]] && $GH_ENABLED; then
                        local _tf="$repo_root/specs/$short_name/tasks.md"
                        [[ -f "$_tf" ]] && gh_create_task_issues "$repo_root" "$epic_num" "$_tf"
                    fi
                    break
                else
                    retries=$((retries + 1))
                    # Iterative phases: log as "rounds" not "retries"
                    if [[ "$state" == "clarify" || "$state" == "analyze" || "$state" == "analyze-verify" ]]; then
                        log INFO "${state^} round $retries/${PHASE_MAX_RETRIES[$state]:-5} — observations remain, re-running in fresh context"
                    else
                        log WARN "Phase $state did not advance (attempt $((retries))/${PHASE_MAX_RETRIES[$state]:-3}, exit=$phase_exit)"
                    fi
                fi
            else
                retries=$((retries + 1))
                if [[ $phase_exit -eq 42 ]]; then
                    local backoff=$((30 * retries))
                    log WARN "Rate limited — backing off ${backoff}s before retry $retries/${PHASE_MAX_RETRIES[$state]:-3}"
                    sleep "$backoff"
                else
                    log WARN "Phase $state failed (exit $phase_exit), retry $retries/${PHASE_MAX_RETRIES[$state]:-3}"
                fi
            fi
        done

        if [[ $retries -ge ${PHASE_MAX_RETRIES[$state]:-3} ]]; then
            # Iterative phases: force-advance instead of erroring
            local spec_dir="$repo_root/specs/$short_name"
            if [[ "$state" == "clarify" ]] && [[ -f "$spec_dir/spec.md" ]]; then
                log WARN "Clarify: max $retries rounds reached — forcing advance to plan"
                echo -e "\n<!-- CLARIFY_COMPLETE -->" >> "$spec_dir/spec.md"
                git -C "$repo_root" add "$spec_dir/spec.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): force-advance clarify after ${retries} rounds" 2>/dev/null || true
                _accumulate_phase_cost "$repo_root"
                continue
            elif [[ "$state" == "clarify-verify" ]] && [[ -f "$spec_dir/spec.md" ]]; then
                log WARN "Clarify-verify: max $retries attempts — forcing advance to plan"
                echo -e "\n<!-- CLARIFY_VERIFIED -->" >> "$spec_dir/spec.md"
                git -C "$repo_root" add "$spec_dir/spec.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): force-advance clarify-verify after ${retries} attempts" 2>/dev/null || true
                _accumulate_phase_cost "$repo_root"
                continue
            elif [[ "$state" == "design-read" ]]; then
                log WARN "Design-read: max $retries attempts — skipping design extraction"
                echo "# Design Context: Skipped (extraction failed after $retries attempts)" \
                    > "$spec_dir/design-context.md"
                git -C "$repo_root" add "$spec_dir/design-context.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): skip design-read after ${retries} attempts" 2>/dev/null || true
                _accumulate_phase_cost "$repo_root"
                continue
            elif [[ "$state" == "analyze" ]] && [[ -f "$spec_dir/tasks.md" ]]; then
                log WARN "Analyze: max $retries rounds reached — forcing advance to verify"
                if ! grep -q '<!-- FIXES APPLIED -->' "$spec_dir/tasks.md"; then
                    echo -e "\n<!-- FIXES APPLIED -->" >> "$spec_dir/tasks.md"
                fi
                git -C "$repo_root" add "$spec_dir/tasks.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): force-advance analyze after ${retries} rounds" 2>/dev/null || true
                _accumulate_phase_cost "$repo_root"
                continue
            elif [[ "$state" == "analyze-verify" ]] && [[ -f "$spec_dir/tasks.md" ]]; then
                log WARN "Analyze-verify: max $retries attempts — forcing advance to implement"
                # Remove FIXES APPLIED marker using portable sed
                sed '/<!-- FIXES APPLIED -->/d' "$spec_dir/tasks.md" > "$spec_dir/tasks.md.tmp" && \
                mv "$spec_dir/tasks.md.tmp" "$spec_dir/tasks.md"
                if ! grep -q '<!-- ANALYZED -->' "$spec_dir/tasks.md"; then
                    echo -e "\n<!-- ANALYZED -->" >> "$spec_dir/tasks.md"
                fi
                git -C "$repo_root" add "$spec_dir/tasks.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): force-advance analyze-verify after ${retries} attempts" 2>/dev/null || true
                _accumulate_phase_cost "$repo_root"
                continue
            elif [[ "$state" == "implement" ]] && [[ -f "$spec_dir/tasks.md" ]]; then
                if ! ${ALLOW_DEFERRED:-false}; then
                    log ERROR "Implement stuck after $retries attempts. Re-run with --allow-deferred to defer stuck tasks."
                    log ERROR "Resume with: ./autopilot.sh $epic_num --allow-deferred"
                    return 1
                fi

                # Scope deferral to the stuck phase only
                local stuck_phase
                stuck_phase=$(get_current_impl_phase "$spec_dir/tasks.md")

                # Guard against empty stuck_phase
                if [[ -z "$stuck_phase" ]]; then
                    log ERROR "Cannot determine stuck phase — no incomplete tasks found. This should not happen."
                    return 1
                fi

                log WARN "Implement: deferring incomplete tasks in Phase $stuck_phase only"

                # Convert - [ ] to - [-] ONLY within the stuck phase section
                local in_phase=false phase_num=""
                local tmpfile="$spec_dir/tasks.md.tmp"
                : > "$tmpfile"
                while IFS= read -r line; do
                    if [[ "$line" =~ ^##[#]?\ *Phase\ ([0-9]+) ]]; then
                        phase_num="${BASH_REMATCH[1]}"
                        if [[ "$phase_num" == "$stuck_phase" ]]; then
                            in_phase=true
                        elif $in_phase; then
                            in_phase=false
                        fi
                    fi
                    if $in_phase && [[ "$line" =~ ^-\ \[\ \] ]]; then
                        echo "${line/- \[ \]/- [-]}" >> "$tmpfile"
                    else
                        echo "$line" >> "$tmpfile"
                    fi
                done < "$spec_dir/tasks.md"
                mv "$tmpfile" "$spec_dir/tasks.md"

                # Append audit marker
                local deferred_count
                deferred_count=$(grep -c '^\- \[-\]' "$spec_dir/tasks.md" 2>/dev/null) || deferred_count=0
                printf '\n<!-- FORCE_DEFERRED: Phase %s (%d tasks) after %d implement attempts -->\n' \
                    "$stuck_phase" "$deferred_count" "$retries" >> "$spec_dir/tasks.md"

                # Track cascading deferrals
                consecutive_deferred=$((consecutive_deferred + 1))
                if [[ $consecutive_deferred -ge 2 ]]; then
                    log ERROR "2 consecutive phases deferred — stopping to avoid token burn. Resume with: ./autopilot.sh $epic_num --allow-deferred"
                    return 1
                fi

                git -C "$repo_root" add "$spec_dir/tasks.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): defer Phase $stuck_phase tasks after ${retries} implement attempts" 2>/dev/null || true
                _accumulate_phase_cost "$repo_root"
                continue
            fi
            log ERROR "Phase $state stuck after ${PHASE_MAX_RETRIES[$state]:-3} attempts. Stopping."
            log ERROR "Resume with: ./autopilot.sh $epic_num"
            return 1
        fi
    done
}

# run_finalize() is in autopilot-finalize.sh (sourced above)

# ─── Entry Point ─────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    # Preflight: jq required for stream-json processing
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required for autopilot observability. Install: sudo apt install jq" >&2
        exit 1
    fi

    local repo_root
    repo_root="$(get_repo_root)"
    REPO_ROOT="$repo_root"
    init_logging "$repo_root"
    load_project_config "$repo_root"

    # Preflight: verify project tools are available
    verify_preflight_tools "$repo_root" || exit 1

    # GitHub Projects integration
    gh_detect
    if $GH_ENABLED; then
        gh_ensure_project "$repo_root" || true
    fi

    # Validate status options are populated
    if $GH_ENABLED; then
        if [[ -z "${GH_STATUS_OPT[Todo]:-}" ]] || \
           [[ -z "${GH_STATUS_OPT[In Progress]:-}" ]] || \
           [[ -z "${GH_STATUS_OPT[Done]:-}" ]]; then
            log WARN "GitHub sync: missing required status options — disabling"
            GH_ENABLED=false
        fi
    fi

    # Handle --github-resync mode (exits after sync)
    if $GITHUB_RESYNC; then
        if ! $GH_ENABLED; then
            log ERROR "GitHub sync unavailable — check gh auth"
            exit 1
        fi
        gh_resync "$repo_root"
        exit 0
    fi

    # Base branch for merges (from project.env or fallback)
    BASE_BRANCH="${BASE_BRANCH:-master}"
    MERGE_TARGET="$(detect_merge_target "$repo_root")"

    log INFO "Autopilot started (auto-continue=$AUTO_CONTINUE, dry-run=$DRY_RUN, silent=$SILENT)"
    log INFO "Repository: $repo_root (base: $BASE_BRANCH, merge target: $MERGE_TARGET)"
    log INFO "Dashboard: run ${BOLD}autopilot-watch.sh${RESET} in another terminal"

    # Trap for clean exit
    trap 'rm -f "${TMPDIR:-/tmp}"/autopilot-prompt-* 2>/dev/null; if [[ ${#TARGET_EPICS[@]} -gt 0 ]]; then log WARN "Autopilot interrupted. Resume with: ./autopilot.sh ${TARGET_EPICS[0]}-${TARGET_EPICS[-1]}"; elif [[ -n "$TARGET_EPIC" ]]; then log WARN "Autopilot interrupted. Resume with: ./autopilot.sh $TARGET_EPIC"; else log WARN "Autopilot interrupted. Resume with: ./autopilot.sh"; fi; exit 130' INT TERM

    while true; do
        # Find next epic
        local epic_info
        if [[ ${#TARGET_EPICS[@]} -gt 0 ]]; then
            epic_info="$(find_next_epic "$repo_root" "" "$(IFS=,; echo "${TARGET_EPICS[*]}")")"
        else
            epic_info="$(find_next_epic "$repo_root" "$TARGET_EPIC")"
        fi

        if [[ -z "$epic_info" ]]; then
            if [[ ${#TARGET_EPICS[@]} -gt 0 ]]; then
                log OK "All epics in range ${TARGET_EPICS[0]}-${TARGET_EPICS[-1]} complete"
            elif [[ -n "$TARGET_EPIC" ]]; then
                log ERROR "Epic $TARGET_EPIC not found"
            else
                log OK "All epics complete!"
                run_finalize "$repo_root" || log ERROR "Finalize failed"
            fi
            break
        fi

        # Parse epic info
        IFS='|' read -r epic_num short_name title epic_file <<< "$epic_info"
        log INFO "Next epic: $epic_num — $title"

        if $GH_ENABLED; then
            gh_create_epic_issue "$repo_root" "$epic_num" "$title"
        fi

        # Run the epic lifecycle
        if ! run_epic "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"; then
            log ERROR "Epic $epic_num did not complete successfully"
            break
        fi

        # If targeting a specific epic, stop after it
        if [[ -n "$TARGET_EPIC" ]]; then
            break
        fi
        if [[ ${#TARGET_EPICS[@]} -gt 0 ]]; then
            # Remove completed epic from the list
            local remaining=()
            for e in "${TARGET_EPICS[@]}"; do
                [[ "$e" != "$epic_num" ]] && remaining+=("$e")
            done
            TARGET_EPICS=("${remaining[@]}")
            if [[ ${#TARGET_EPICS[@]} -eq 0 ]]; then
                log OK "Range complete"
                break
            fi
        fi

        # Auto-continue or pause
        if ! $AUTO_CONTINUE; then
            echo ""
            echo -n "Continue to next epic? [y/N] "
            read -r confirm
            if [[ ! "$confirm" =~ ^[Yy] ]]; then
                log INFO "Stopped by user between epics"
                break
            fi
        else
            log INFO "Auto-continuing to next epic..."
        fi
    done

    log OK "Autopilot finished"
}

main "$@"
