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

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "ERROR: bash 4.3+ required (found $BASH_VERSION). Install via: brew install bash" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/autopilot-lib.sh"
source "$SCRIPT_DIR/autopilot-stream.sh"
source "$SCRIPT_DIR/autopilot-prompts.sh"
source "$SCRIPT_DIR/autopilot-github.sh"
source "$SCRIPT_DIR/autopilot-review-helpers.sh"
source "$SCRIPT_DIR/autopilot-review.sh"
source "$SCRIPT_DIR/autopilot-merge.sh"
source "$SCRIPT_DIR/autopilot-verify.sh"
source "$SCRIPT_DIR/autopilot-gates.sh"
source "$SCRIPT_DIR/autopilot-finalize.sh"
source "$SCRIPT_DIR/autopilot-validate.sh"
source "$SCRIPT_DIR/autopilot-design.sh"
source "$SCRIPT_DIR/autopilot-requirements.sh"

# ─── Cascade Circuit Breaker ────────────────────────────────────────────────

# Cascade circuit breaker — prevents multiple gates force-skipping in series.
# force_skip_count is a local in run_epic(); bash functions share caller's locals.
_check_cascade_limit() {
    local repo_root="$1" epic_num="$2" tasks_file="$3"
    force_skip_count=$((force_skip_count + 1))
    local limit=${FORCE_SKIP_CASCADE_LIMIT:-3}

    if [[ $force_skip_count -ge $limit ]]; then
        log ERROR "CASCADE LIMIT REACHED: $force_skip_count gates force-skipped in epic $epic_num"
        log ERROR "Resume with: ./autopilot.sh $epic_num --allow-cascade"
        echo "<!-- CASCADE_LIMIT_REACHED -->" >> "$tasks_file"
        git -C "$repo_root" add "$tasks_file" 2>/dev/null || true
        git -C "$repo_root" commit -m "cascade($epic_num): limit reached ($force_skip_count gates force-skipped)" \
            --no-verify 2>/dev/null || true
        return 1
    elif [[ $force_skip_count -eq $((limit - 1)) ]]; then
        log WARN "CASCADE WARNING: $force_skip_count of $limit gates force-skipped. Next force-skip will halt."
    else
        log WARN "$force_skip_count gate(s) force-skipped so far in epic $epic_num"
    fi
    return 0
}

# ─── Clarify Summary Event ─────────────────────────────────────────────────

# Emit a clarify_summary event to the events log.
# Args: repo_root epic_num rounds cv_rejections force_advanced
_emit_clarify_summary() {
    local repo_root="$1" epic_num="$2" rounds="$3" cv_rejections="$4" force_advanced="$5"
    local events_log="$repo_root/.specify/logs/events.jsonl"
    mkdir -p "$(dirname "$events_log")"
    jq -nc \
        --arg event "clarify_summary" \
        --arg epic "$epic_num" \
        --argjson rounds "${rounds:-0}" \
        --argjson cv_rejections "${cv_rejections:-0}" \
        --argjson force_advanced "${force_advanced:-false}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event:$event, epic:$epic, rounds:$rounds, cv_rejections:$cv_rejections, force_advanced:$force_advanced, timestamp:$ts}' \
        >> "$events_log"
}

# Emit an analyze_summary event to the events log.
# Args: repo_root epic_num rounds verify_rejections force_advanced
_emit_analyze_summary() {
    local repo_root="$1" epic_num="$2" rounds="$3" verify_rejections="$4" force_advanced="$5"
    local events_log="$repo_root/.specify/logs/events.jsonl"
    mkdir -p "$(dirname "$events_log")"
    jq -nc \
        --arg event "analyze_summary" \
        --arg epic "$epic_num" \
        --argjson rounds "${rounds:-0}" \
        --argjson verify_rejections "${verify_rejections:-0}" \
        --argjson force_advanced "${force_advanced:-false}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event:$event, epic:$epic, rounds:$rounds, verify_rejections:$verify_rejections, force_advanced:$force_advanced, timestamp:$ts}' \
        >> "$events_log"
}

# Emit a security_summary event to the events log.
# Args: repo_root epic_num rounds verify_rejections force_advanced
_emit_security_summary() {
    local repo_root="$1" epic_num="$2" rounds="$3" verify_rejections="$4" force_advanced="$5"
    local events_log="$repo_root/.specify/logs/events.jsonl"
    mkdir -p "$(dirname "$events_log")"
    jq -nc \
        --arg event "security_summary" \
        --arg epic "$epic_num" \
        --argjson rounds "${rounds:-0}" \
        --argjson verify_rejections "${verify_rejections:-0}" \
        --argjson force_advanced "${force_advanced:-false}" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{event:$event, epic:$epic, rounds:$rounds, verify_rejections:$verify_rejections, force_advanced:$force_advanced, timestamp:$ts}' \
        >> "$events_log"
}

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
    [conflict-resolve]="$OPUS"
    [verify-requirements]="$SONNET"
    [requirements-fix]="$SONNET"
    [requirements-recheck]="$SONNET"
    [security-review]="$OPUS"
    [security-fix]="$OPUS"
    [security-verify]="$OPUS"
    [self-review]="$OPUS"
    [review-fix]="$OPUS"
    [rebase-fix]="$OPUS"
    [verify-ci-fix]="$SONNET"
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
    [conflict-resolve]="Read,Write,Edit,Bash,Glob,Grep"
    [verify-requirements]="Read,Write,Glob,Grep"
    [requirements-fix]="Read,Write,Edit,Bash,Glob,Grep"
    [requirements-recheck]="Read,Write,Glob,Grep,Bash"
    [security-review]="Read,Write,Glob,Grep"
    [security-fix]="Read,Write,Edit,Bash,Glob,Grep"
    [security-verify]="Read,Glob,Grep,Bash"
    [self-review]="Read,Glob,Grep,Bash"
    [review-fix]="Read,Write,Edit,Bash,Glob,Grep"
    [rebase-fix]="Read,Write,Edit,Bash,Glob,Grep"
    [verify-ci-fix]="Read,Write,Edit,Bash,Glob,Grep"
)

# Phase → max retries (convergence phases get more attempts)
declare -A PHASE_MAX_RETRIES=(
    [specify]=3
    [clarify]=8
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
    [conflict-resolve]=3
    [requirements-recheck]=1
    [security-review]=1
    [security-fix]=1
    [security-verify]=1
    [self-review]=1
    [review-fix]=3
    [rebase-fix]=3
    [verify-ci-fix]=3
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
ALLOW_DEFERRED="${ALLOW_DEFERRED:-true}"
SKIP_CODERABBIT=false
SKIP_REVIEW=false
STRICT_MODE=false
SECURITY_FORCE_SKIP_ALLOWED="${SECURITY_FORCE_SKIP_ALLOWED:-true}"
REQUIREMENTS_FORCE_SKIP_ALLOWED="${REQUIREMENTS_FORCE_SKIP_ALLOWED:-true}"
FORCE_SKIP_CASCADE_LIMIT="${FORCE_SKIP_CASCADE_LIMIT:-3}"
MAX_ITERATIONS=""   # CLI override for iteration safety limit
AUTO_REVERT_ON_FAILURE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto-revert)      AUTO_REVERT_ON_FAILURE=true ;;
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
            --strict)           STRICT_MODE=true ;;
            --allow-cascade) FORCE_SKIP_CASCADE_LIMIT=99 ;;
            --allow-main-merge) ALLOW_MAIN_MERGE=true ;;
            --skip-review|--skip-coderabbit)  SKIP_REVIEW=true ;;
            --max-iterations)
                shift
                MAX_ITERATIONS="$1"
                if [[ -z "$MAX_ITERATIONS" ]] || ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
                    echo "ERROR: --max-iterations requires a positive integer" >&2; exit 1
                fi
                if [[ $((10#$MAX_ITERATIONS)) -le 0 ]]; then
                    echo "ERROR: --max-iterations must be > 0" >&2; exit 1
                fi
                if [[ $((10#$MAX_ITERATIONS)) -lt 20 ]]; then
                    log WARN "MAX_ITERATIONS=$MAX_ITERATIONS is below typical minimum (~18 phases). Possible early termination."
                fi
                ;;
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
                echo "  --strict             Halt on all gate failures (disable auto-advance)"
                echo "  --strict-deps        Block on unmerged dependencies (default: warn only)"
                echo "  --skip-review        Skip code review during remote merge (alias: --skip-coderabbit)"
                echo "  --allow-cascade      Raise cascade circuit-breaker limit to 99 (allow many gate skips)"
                echo "  --allow-main-merge   Allow merge to main/master even when staging branch exists"
                echo "  --max-iterations N   Override iteration safety limit (default: 60)"
                echo "  --auto-revert        Auto-revert merge on finalize failure (opt-in)"
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

    # Validate phase exists in required arrays (missing key + set -u = crash)
    if [[ ! -v PHASE_MODEL["$phase"] ]] || [[ ! -v PHASE_TOOLS["$phase"] ]]; then
        log ERROR "Unknown phase '$phase' — missing from PHASE_MODEL or PHASE_TOOLS"
        return 1
    fi

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

    # Circuit breaker: wait if Claude has been failing
    _cb_gate || return 99
    env -u CLAUDECODE claude -p "Read the file ${prompt_file} and follow ALL instructions within it exactly." \
        --model "$model" \
        --allowedTools "$tools" \
        --output-format stream-json \
        --verbose \
        --dangerously-skip-permissions \
        2>&1 | process_stream "$epic_num" "$phase" || exit_code=$?

    # Circuit breaker: record outcome
    if [[ $exit_code -eq 42 ]]; then
        _cb_record_failure
    elif [[ $exit_code -eq 0 ]]; then
        _cb_record_success
    fi

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
    local round="${7:-1}" max_rounds="${8:-5}"
    local clarify_total_arg="${9:-}" clarify_cycle_arg="${10:-}"

    local prompt=""

    case "$phase" in
        specify)
            prompt="$(prompt_specify "$epic_num" "$title" "$epic_file" "$repo_root")"
            ;;
        clarify)
            prompt="$(prompt_clarify "$epic_num" "$title" "$epic_file" "$repo_root" "$spec_dir" "$round" "$max_rounds" "$clarify_total_arg" "$clarify_cycle_arg")"
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
            prompt="$(prompt_analyze "$epic_num" "$title" "$repo_root" "$spec_dir" "$round" "$max_rounds")"
            ;;
        analyze-verify)
            prompt="$(prompt_analyze_verify "$epic_num" "$title" "$repo_root" "$spec_dir" "$round" "$max_rounds")"
            ;;
        implement)
            local cur_phase total_phases
            cur_phase=$(get_current_impl_phase "$spec_dir/tasks.md")
            total_phases=$(count_phases "$spec_dir/tasks.md")
            prompt="$(prompt_implement "$epic_num" "$title" "$repo_root" "$spec_dir" "${cur_phase:-1}" "${total_phases:-1}")"
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
            local diff_sha="${LAST_MERGE_SHA:-HEAD~2}"
            local diff_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-content-XXXXXX")
            local max_diff=${CRYSTALLIZE_MAX_DIFF_CHARS:-50000}

            # Always include stat (small, gives full file list)
            local diff_stat
            diff_stat=$(git -C "$repo_root" diff "${diff_sha}^..${diff_sha}" --stat 2>/dev/null || echo "(unavailable)")

            # Full diff with tail truncation
            local diff_full
            diff_full=$(git -C "$repo_root" diff "${diff_sha}^..${diff_sha}" 2>/dev/null || echo "(unavailable)")
            local diff_len=${#diff_full}
            if [[ $diff_len -gt $max_diff ]]; then
                diff_full="[... first $((diff_len - max_diff)) chars truncated — showing last ${max_diff} chars ...]
${diff_full: -$max_diff}"
            fi

            # File list
            local diff_files
            diff_files=$(git -C "$repo_root" diff --name-only "${diff_sha}^..${diff_sha}" 2>/dev/null || echo "(unavailable)")

            printf '%s\n\n' "FILES CHANGED:" > "$diff_file"
            printf '%s\n\n' "$diff_files" >> "$diff_file"
            printf '%s\n\n' "DIFF STAT:" >> "$diff_file"
            printf '%s\n\n' "$diff_stat" >> "$diff_file"
            printf '%s\n\n' "FULL DIFF:" >> "$diff_file"
            printf '%s' "$diff_full" >> "$diff_file"

            # Module map extraction (grounded source of truth for crystallize)
            local grep_output=""
            case "${PROJECT_LANG:-unknown}" in
                Go)
                    grep_output=$(grep -rnE '^func\s+(\([^)]+\)\s+)?[A-Z]\w*\(' "$repo_root" \
                        --include='*.go' --exclude-dir=vendor --exclude-dir=.git \
                        --exclude-dir=node_modules --exclude-dir=third_party \
                        --exclude='*_test.go' 2>/dev/null | head -200 || true)
                    ;;
                Node/JS/TS|Node-Monorepo)
                    grep_output=$(grep -rnE '^export\s+(async\s+)?(function|const|class|interface|type|enum)' "$repo_root" \
                        --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
                        --exclude-dir=vendor --exclude-dir=.git --exclude-dir=node_modules \
                        --exclude-dir=dist --exclude='*.test.*' --exclude='*.spec.*' 2>/dev/null | head -200 || true)
                    ;;
                Python)
                    grep_output=$(grep -rnE '^(def|class) ' "$repo_root" \
                        --include='*.py' --exclude-dir=vendor --exclude-dir=.git \
                        --exclude-dir=node_modules --exclude-dir=__pycache__ \
                        --exclude='test_*' --exclude='*_test.py' 2>/dev/null | head -200 || true)
                    ;;
                Rust)
                    grep_output=$(grep -rnE '^\s*pub\s+(fn|struct|enum|trait)' "$repo_root" \
                        --include='*.rs' --exclude-dir=vendor --exclude-dir=.git \
                        --exclude-dir=target 2>/dev/null | head -200 || true)
                    ;;
            esac

            if [[ -n "$grep_output" ]]; then
                printf '\n\n%s\n' "SOURCE MODULE MAP (pre-computed from actual source files):" >> "$diff_file"
                printf '%s\n' "$grep_output" >> "$diff_file"
            fi

            prompt="$(prompt_crystallize "$epic_num" "$title" "$repo_root" "$short_name" "$diff_file")"
            rm -f "$diff_file"
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

    # Guardrail: refuse merge to main/master when staging exists
    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]] && \
       { git -C "$repo_root" rev-parse --verify origin/staging &>/dev/null || \
         git -C "$repo_root" rev-parse --verify staging &>/dev/null; } && \
       [[ "${ALLOW_MAIN_MERGE:-false}" != "true" ]]; then
        log ERROR "Refusing to merge to '$MERGE_TARGET' — a 'staging' branch exists."
        log ERROR "Set BASE_BRANCH=staging in .specify/project.env, or pass --allow-main-merge"
        return 1
    fi

    # Pre-merge gate history check
    local tasks_file="$repo_root/specs/$short_name/tasks.md"
    local skip_summary="" skip_count=0
    grep -q 'SECURITY_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Security: findings force-skipped\n"; skip_count=$((skip_count+1)); }
    grep -q 'REQUIREMENTS_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Requirements: gaps force-skipped\n"; skip_count=$((skip_count+1)); }
    grep -q 'REVIEW_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - Review: issues force-skipped\n"; skip_count=$((skip_count+1)); }
    grep -q 'VERIFY_CI_FORCE_SKIPPED' "$tasks_file" 2>/dev/null && { skip_summary+="  - CI: failures force-skipped\n"; skip_count=$((skip_count+1)); }

    if [[ $skip_count -gt 0 ]]; then
        log WARN "PRE-MERGE RISK SUMMARY: $skip_count gate(s) force-skipped:"
        printf "%b" "$skip_summary" | while read -r line; do log WARN "$line"; done
    fi

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
    if [[ -n "$(git -C "$repo_root" status --porcelain --ignore-submodules=all 2>/dev/null)" ]]; then
        log WARN "Uncommitted changes detected before merge:"
        git -C "$repo_root" status --short | while IFS= read -r line; do
            log WARN "  $line"
        done
        git -C "$repo_root" add -A
        if ! git -C "$repo_root" diff --cached --quiet 2>/dev/null; then
            git -C "$repo_root" commit -m "chore(${epic_num}): commit remaining changes before merge" || return 1
        fi
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

    # Capture merge commit SHA before YAML marker commit moves HEAD forward
    LAST_MERGE_SHA=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
    if [[ -n "$LAST_MERGE_SHA" ]]; then
        log INFO "Merge commit SHA: $LAST_MERGE_SHA"
    fi

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
            rm -rf "${repo_root:?}/specs/${correct_name:?}"
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
    local max_iter=${MAX_ITERATIONS:-70}
    local consecutive_deferred=0
    local force_skip_count=0
    local force_skip_cascade_limit=${FORCE_SKIP_CASCADE_LIMIT:-3}
    local prev_tasks_hash="" prev_commit_sha="" same_hash_count=0 oscillation_stalled=false outer_prev_state=""
    local clarify_total_rounds=0 clarify_cycle=1 clarify_cv_rejections=0
    local analyze_total_rounds=0 analyze_cycle=1 analyze_verify_rejections=0

    while true; do
        total_iterations=$((total_iterations + 1))
        if [[ $total_iterations -gt $max_iter ]]; then
            log ERROR "Epic $epic_num exceeded $max_iter total phase iterations — possible oscillation. Stopping."
            log ERROR "Resume with: ./autopilot.sh $epic_num"

            # Abort any in-progress rebase/merge
            [[ -d "$repo_root/.git/rebase-merge" ]] || [[ -d "$repo_root/.git/rebase-apply" ]] && \
                git -C "$repo_root" rebase --abort 2>/dev/null || true
            [[ -f "$repo_root/.git/MERGE_HEAD" ]] && \
                git -C "$repo_root" merge --abort 2>/dev/null || true

            # Emergency commit of dirty working tree
            if [[ -n "$(git -C "$repo_root" status --porcelain --ignore-submodules=all 2>/dev/null)" ]]; then
                log WARN "Saving uncommitted work before halt..."
                git -C "$repo_root" add -A
                git -C "$repo_root" diff --cached --quiet 2>/dev/null || \
                    git -C "$repo_root" commit --no-verify \
                        -m "emergency(${epic_num}): max-iter halt [state: ${state:-unknown}]" 2>/dev/null || true
            fi

            return 1
        fi

        state="$(detect_state "$repo_root" "$epic_num" "$short_name")"
        log INFO "Detected state: $state"

        # Oscillation detection: track tasks hash + commit SHA + state across outer-loop iterations
        local cur_tasks_hash cur_commit_sha
        cur_tasks_hash=$(_file_hash "$repo_root/specs/$short_name/tasks.md")
        cur_commit_sha=$(git -C "$repo_root" log -1 --format=%H 2>/dev/null || echo "none")

        if [[ "$cur_tasks_hash" == "$prev_tasks_hash" && "$cur_commit_sha" == "$prev_commit_sha" && "$state" == "$outer_prev_state" ]]; then
            same_hash_count=$((same_hash_count + 1))
            if [[ $same_hash_count -ge 3 ]]; then
                log WARN "Phase '$state' stalled for 3 outer-loop iterations — deferring"
                oscillation_stalled=true
            fi
        else
            same_hash_count=0
            oscillation_stalled=false
        fi
        prev_tasks_hash="$cur_tasks_hash"
        prev_commit_sha="$cur_commit_sha"
        outer_prev_state="$state"

        local _tasks_file=""
        [[ -n "$short_name" ]] && _tasks_file="$repo_root/specs/$short_name/tasks.md"
        gh_sync_phase "$repo_root" "$epic_num" "$state" "$_tasks_file"

        if [[ "$state" == "done" ]]; then
            log OK "Epic $epic_num is complete and merged"
            return 0
        fi

        # FR coverage check: warn (non-blocking) on transition to implement
        if [[ "$state" == "implement" ]] && [[ -n "$short_name" ]]; then
            check_fr_coverage "$repo_root/specs/$short_name" || true
        fi

        if [[ "$state" == "verify-requirements" ]]; then
            if ! _run_requirements_gate "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"; then
                log ERROR "Requirements verification halted (--strict mode). Remove --strict to allow auto-advance."
                return 1
            fi
            continue  # re-detect state → should now be "security-review"
        fi

        if [[ "$state" == "security-review" ]]; then
            if ! _run_security_gate "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"; then
                log ERROR "Security gate halted pipeline (--strict mode). Remove --strict to allow auto-advance."
                return 1
            fi
            continue  # re-detect state → should now be "review"
        fi

        # Verify-CI gate — run full CI pipeline before review
        if [[ "$state" == "verify-ci" ]]; then
            _run_verify_ci_gate "$repo_root" "$epic_num" "$short_name" "$title" "$epic_file"
            continue  # re-detect state → should now be "review"
        fi

        if [[ "$state" == "review" ]]; then
            local _tasks_md="$repo_root/specs/$short_name/tasks.md"
            local _cr_status_file="$repo_root/specs/$short_name/.last-cr-status"

            if [[ -f "$_tasks_md" ]] && grep -q '<!-- TIERED_REVIEW_COMPLETE -->' "$_tasks_md"; then
                log INFO "Resuming: tiered review already complete — skipping to merge gate"
                [[ -f "$_cr_status_file" ]] && LAST_CR_STATUS=$(<"$_cr_status_file")
            else
                # Review first, then merge
                local retries=0
                while [[ $retries -lt ${PHASE_MAX_RETRIES[$state]:-3} ]]; do
                    if run_phase "review" "$epic_num" "$short_name" "$title" "$epic_file" "$repo_root" "$((retries + 1))" "${PHASE_MAX_RETRIES[$state]:-3}"; then
                        _accumulate_phase_cost "$repo_root"
                        break
                    fi
                    _accumulate_phase_cost "$repo_root"
                    retries=$((retries + 1))
                    log WARN "Review attempt $retries/${PHASE_MAX_RETRIES[$state]:-3} failed, retrying..."
                done

                if [[ $retries -ge ${PHASE_MAX_RETRIES[$state]:-3} ]]; then
                    log WARN "Review prompt failed ${PHASE_MAX_RETRIES[$state]:-3} times — force-advancing to tiered review"
                    _restore_clean_working_tree "$repo_root"
                fi

                log INFO "Review phase complete — transitioning to merge gate"
                log INFO "Current branch: $(git -C "$repo_root" branch --show-current 2>/dev/null || echo 'unknown')"
                log INFO "Working tree clean: $(git -C "$repo_root" status --porcelain 2>/dev/null | wc -l | tr -d ' ') uncommitted files"

                # ── Tiered automated review (CodeRabbit / Codex / Claude self-review) ──
                if [[ "${SKIP_REVIEW:-${SKIP_CODERABBIT:-false}}" != "true" ]]; then
                    local events_log="$repo_root/.specify/logs/events.jsonl"
                    _tiered_review "$repo_root" "$MERGE_TARGET" "$epic_num" "$title" "$short_name" "$events_log" || {
                        log ERROR "Tiered review failed — halting before merge"
                        return 1
                    }
                    # Write resumability marker
                    if [[ -f "$_tasks_md" ]] && ! grep -q '<!-- TIERED_REVIEW_COMPLETE -->' "$_tasks_md"; then
                        echo "" >> "$_tasks_md"
                        echo "<!-- TIERED_REVIEW_COMPLETE -->" >> "$_tasks_md"
                        (cd "$repo_root" && git add "$_tasks_md" && \
                         git commit -m "chore(${epic_num}): tiered review complete" 2>/dev/null || true)
                    fi
                fi

                # ── Advisory self-review (always runs, non-blocking) ──
                local _adv_events_log="$repo_root/.specify/logs/events.jsonl"
                _advisory_self_review "$repo_root" "$MERGE_TARGET" "$epic_num" "$title" "$short_name" "$_adv_events_log" || \
                    log WARN "Advisory self-review error — continuing (non-blocking)"

                # Persist LAST_CR_STATUS for resume
                echo "$LAST_CR_STATUS" > "$_cr_status_file"
            fi

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
            if ! run_phase "crystallize" "$epic_num" "$short_name" "$title" "$epic_file" "$repo_root" "1" "1"; then
                log WARN "Crystallize phase failed — continuing (non-blocking)"
            fi
            # Post-crystallize validation (warn-only)
            if [[ -f "$repo_root/CLAUDE.md" ]]; then
                if ! grep -q '<!-- MANUAL ADDITIONS START -->' "$repo_root/CLAUDE.md" 2>/dev/null; then
                    log WARN "crystallize: CLAUDE.md missing MANUAL ADDITIONS START marker"
                elif ! grep -q '<!-- MANUAL ADDITIONS END -->' "$repo_root/CLAUDE.md" 2>/dev/null; then
                    log WARN "crystallize: CLAUDE.md missing MANUAL ADDITIONS END marker"
                else
                    local manual_lines
                    manual_lines=$(sed -n '/<!-- MANUAL ADDITIONS START -->/,/<!-- MANUAL ADDITIONS END -->/p' "$repo_root/CLAUDE.md" 2>/dev/null | wc -l | tr -d ' ')
                    if [[ "$manual_lines" -gt 52 ]]; then
                        log WARN "crystallize: CLAUDE.md MANUAL ADDITIONS is ${manual_lines} lines (budget: 50)"
                    fi
                fi
            fi
            if [[ -f "$repo_root/.specify/memory/architecture.md" ]]; then
                local arch_lines
                arch_lines=$(wc -l < "$repo_root/.specify/memory/architecture.md" 2>/dev/null | tr -d ' ')
                if [[ "$arch_lines" -gt 120 ]]; then
                    log WARN "crystallize: architecture.md is ${arch_lines} lines (budget: 120)"
                fi
            fi
            _accumulate_phase_cost "$repo_root"

            # Write post-epic summary
            write_epic_summary "$repo_root" "$epic_num" "$short_name" "$title" "$epic_total_cost"
            return 0
        fi

        # Run the phase with retry logic
        local retries=0
        local prev_state="$state"

        # Capture impl phase before invoke for phase-advance detection
        local prev_impl_phase=""
        if [[ "$state" == "implement" ]] && [[ -n "$short_name" ]]; then
            prev_impl_phase=$(get_current_impl_phase "$repo_root/specs/$short_name/tasks.md")
        fi

        while [[ $retries -lt ${PHASE_MAX_RETRIES[$state]:-3} ]]; do
            local phase_exit=0
            run_phase "$state" "$epic_num" "$short_name" "$title" "$epic_file" "$repo_root" "$((retries + 1))" "${PHASE_MAX_RETRIES[$state]:-3}" "$clarify_total_rounds" "$clarify_cycle" || phase_exit=$?
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

                # Phase-advance detection for implement (sub-phase progress)
                if [[ "$state" == "implement" ]] && [[ -n "$short_name" ]]; then
                    local new_impl_phase
                    new_impl_phase=$(get_current_impl_phase "$repo_root/specs/$short_name/tasks.md")
                    if [[ "$new_impl_phase" != "$prev_impl_phase" ]]; then
                        log OK "Implement phase advanced: $prev_impl_phase -> $new_impl_phase"
                        consecutive_deferred=0
                        retries=0
                        prev_tasks_hash=""
                        prev_commit_sha=""
                        same_hash_count=0
                        prev_impl_phase="$new_impl_phase"
                        continue
                    fi
                fi

                # Verify state advanced
                local new_state
                new_state="$(detect_state "$repo_root" "$epic_num" "$short_name")"

                if [[ "$new_state" != "$prev_state" ]]; then
                    log OK "Phase $prev_state → $new_state (exit=$phase_exit)"
                    consecutive_deferred=0  # Reset on successful phase transition

                    # Track CV→clarify rejection cycle
                    if [[ "$prev_state" == "clarify-verify" ]] && [[ "$new_state" == "clarify" ]]; then
                        ((clarify_cycle++))
                        ((clarify_cv_rejections++))
                    fi

                    # Emit clarify_summary when clarify+CV is complete (advances past CV)
                    if [[ "$prev_state" == "clarify-verify" ]] && [[ "$new_state" != "clarify" ]]; then
                        _emit_clarify_summary "$repo_root" "$epic_num" "$clarify_total_rounds" "$clarify_cv_rejections" "false"
                    fi

                    # Track analyze-verify → analyze rejection cycle
                    if [[ "$prev_state" == "analyze-verify" ]] && [[ "$new_state" == "analyze" ]]; then
                        ((analyze_cycle++))
                        ((analyze_verify_rejections++))
                    fi

                    # Emit analyze_summary when analyze+verify is complete (advances past verify)
                    if [[ "$prev_state" == "analyze-verify" ]] && [[ "$new_state" != "analyze" ]]; then
                        _emit_analyze_summary "$repo_root" "$epic_num" "$analyze_total_rounds" "$analyze_verify_rejections" "false"
                    fi

                    # After tasks phase: create task issues
                    if [[ "$prev_state" == "tasks" ]] && $GH_ENABLED; then
                        local _tf="$repo_root/specs/$short_name/tasks.md"
                        [[ -f "$_tf" ]] && gh_create_task_issues "$repo_root" "$epic_num" "$_tf"
                    fi
                    break
                else
                    retries=$((retries + 1))
                    # Iterative phases: log as "rounds" not "retries"
                    if [[ "$state" == "clarify" ]]; then
                        ((clarify_total_rounds++))
                        log INFO "${state^} round $retries/${PHASE_MAX_RETRIES[$state]:-8} (cycle $clarify_cycle, total round $clarify_total_rounds) — observations remain, re-running in fresh context"
                    elif [[ "$state" == "analyze" ]]; then
                        ((analyze_total_rounds++))
                        log INFO "${state^} round $retries/${PHASE_MAX_RETRIES[$state]:-5} (cycle $analyze_cycle, total round $analyze_total_rounds) — observations remain, re-running in fresh context"
                    elif [[ "$state" == "analyze-verify" ]]; then
                        log INFO "${state^} round $retries/${PHASE_MAX_RETRIES[$state]:-5} — observations remain, re-running in fresh context"
                    else
                        log WARN "Phase $state did not advance (attempt $((retries))/${PHASE_MAX_RETRIES[$state]:-3}, exit=$phase_exit)"
                    fi
                fi
            else
                retries=$((retries + 1))
                if [[ $phase_exit -eq 99 ]]; then
                    log ERROR "Prolonged API outage — Claude unreachable. Halting epic."
                    log ERROR "Resume when service recovers: ./autopilot.sh $epic_num"
                    return 1
                elif [[ $phase_exit -eq 42 ]]; then
                    local backoff=$((30 * retries))
                    log WARN "Rate limited — backing off ${backoff}s before retry $retries/${PHASE_MAX_RETRIES[$state]:-3}"
                    sleep "$backoff"
                else
                    log WARN "Phase $state failed (exit $phase_exit), retry $retries/${PHASE_MAX_RETRIES[$state]:-3}"
                fi
            fi
        done

        if [[ "$oscillation_stalled" == "true" ]] || [[ $retries -ge ${PHASE_MAX_RETRIES[$state]:-3} ]]; then
            # Iterative phases: force-advance instead of erroring
            local spec_dir="$repo_root/specs/$short_name"
            if [[ "$state" == "clarify" ]] && [[ -f "$spec_dir/spec.md" ]]; then
                log WARN "Clarify: max $retries rounds reached (cycle $clarify_cycle, total $clarify_total_rounds) — forcing advance to plan"
                echo -e "\n<!-- CLARIFY_COMPLETE -->" >> "$spec_dir/spec.md"
                git -C "$repo_root" add "$spec_dir/spec.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): force-advance clarify after ${retries} rounds (cycle $clarify_cycle, total $clarify_total_rounds)" 2>/dev/null || true
                _emit_clarify_summary "$repo_root" "$epic_num" "$clarify_total_rounds" "$clarify_cv_rejections" "true"
                _accumulate_phase_cost "$repo_root"
                continue
            elif [[ "$state" == "clarify-verify" ]] && [[ -f "$spec_dir/spec.md" ]]; then
                log WARN "Clarify-verify: max $retries attempts (cycle $clarify_cycle, total rounds $clarify_total_rounds) — forcing advance to plan"
                echo -e "\n<!-- CLARIFY_VERIFIED -->" >> "$spec_dir/spec.md"
                git -C "$repo_root" add "$spec_dir/spec.md" && \
                git -C "$repo_root" commit -m "chore(${epic_num}): force-advance clarify-verify after ${retries} attempts (cycle $clarify_cycle)" 2>/dev/null || true
                _emit_clarify_summary "$repo_root" "$epic_num" "$clarify_total_rounds" "$clarify_cv_rejections" "true"
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
                _emit_analyze_summary "$repo_root" "$epic_num" "$analyze_total_rounds" "$analyze_verify_rejections" "true"
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
                _emit_analyze_summary "$repo_root" "$epic_num" "$analyze_total_rounds" "$analyze_verify_rejections" "true"
                _accumulate_phase_cost "$repo_root"
                continue
            elif [[ "$state" == "implement" ]] && [[ -f "$spec_dir/tasks.md" ]]; then
                if ! ${ALLOW_DEFERRED:-false}; then
                    log ERROR "Implement stuck after $retries attempts (deferral disabled by --strict)."
                    log ERROR "Resume without --strict to allow automatic deferral."
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

                # Track cascading deferrals (graduated threshold — max_iter is backstop)
                consecutive_deferred=$((consecutive_deferred + 1))
                if [[ $consecutive_deferred -ge 5 ]]; then
                    log WARN "5 consecutive phases deferred — force-forward, logging and resetting counter"
                    # Log to deferred-phases.log
                    local defer_log="$repo_root/.specify/logs/deferred-phases.log"
                    mkdir -p "$(dirname "$defer_log")"
                    printf '%s  FORCE-FORWARD  epic=%s  phase=%s  consecutive=%d  retries=%d\n' \
                        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$epic_num" "$stuck_phase" "$consecutive_deferred" "$retries" \
                        >> "$defer_log"
                    # Log to skipped-findings.md
                    local skip_md="$spec_dir/skipped-findings.md"
                    {
                        printf '## Force-Forward at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                        printf '- Phase: %s\n' "$stuck_phase"
                        printf '- Consecutive deferrals: %d\n' "$consecutive_deferred"
                        printf '- Implement retries: %d\n\n' "$retries"
                    } >> "$skip_md"
                    consecutive_deferred=0
                elif [[ $consecutive_deferred -eq 4 ]]; then
                    log WARN "4 consecutive phases deferred — force-forward imminent"
                elif [[ $consecutive_deferred -eq 3 ]]; then
                    log WARN "3 consecutive phases deferred — continuing"
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
    # Preflight: jq required for stream-json processing
    if ! command -v jq >/dev/null 2>&1; then
        local install_cmd="sudo apt install jq"
        [[ "$OSTYPE" == darwin* ]] && install_cmd="brew install jq"
        echo "ERROR: jq is required for autopilot observability. Install: $install_cmd" >&2
        exit 1
    fi

    local repo_root
    repo_root="$(get_repo_root)"
    REPO_ROOT="$repo_root"
    init_logging "$repo_root"
    load_project_config "$repo_root"

    # CLI args parsed AFTER project config so flags override project.env
    parse_args "$@"

    # Strict mode: override all permissive defaults
    if [[ "${STRICT_MODE:-false}" == "true" ]]; then
        ALLOW_DEFERRED=false
        FORCE_ADVANCE_ON_REVIEW_STALL=false
        FORCE_ADVANCE_ON_DIMINISHING_RETURNS=false
        FORCE_ADVANCE_ON_REVIEW_ERROR=false
        SECURITY_FORCE_SKIP_ALLOWED=false
        REQUIREMENTS_FORCE_SKIP_ALLOWED=false
        CI_FORCE_SKIP_ALLOWED=false
        FORCE_SKIP_CASCADE_LIMIT=0
        log INFO "Strict mode: all gates will halt on failure"
    fi

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

    if [[ "$MERGE_TARGET" =~ ^(main|master)$ ]]; then
        if git -C "$repo_root" rev-parse --verify staging &>/dev/null || \
           git -C "$repo_root" rev-parse --verify origin/staging &>/dev/null; then
            log WARN "Merging to '$MERGE_TARGET' but a 'staging' branch exists."
            log WARN "Consider setting MERGE_TARGET_BRANCH=staging in .specify/project.env"
        fi
    fi

    log INFO "Autopilot started (auto-continue=$AUTO_CONTINUE, dry-run=$DRY_RUN, silent=$SILENT)"
    log INFO "Repository: $repo_root (base: $BASE_BRANCH, merge target: $MERGE_TARGET)"
    log INFO "Dashboard: run ${BOLD}autopilot-watch.sh${RESET} in another terminal"

    # Trap for clean exit
    trap 'rm -f "${TMPDIR:-/tmp}"/autopilot-{prompt,content}-* 2>/dev/null; if [[ ${#TARGET_EPICS[@]} -gt 0 ]]; then log WARN "Autopilot interrupted. Resume with: ./autopilot.sh ${TARGET_EPICS[0]}-${TARGET_EPICS[-1]}"; elif [[ -n "$TARGET_EPIC" ]]; then log WARN "Autopilot interrupted. Resume with: ./autopilot.sh $TARGET_EPIC"; else log WARN "Autopilot interrupted. Resume with: ./autopilot.sh"; fi; exit 130' INT TERM

    local _rc=0

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
                _rc=1
            else
                log OK "All epics complete!"
                if ! run_finalize "$repo_root"; then
                    log ERROR "Finalize failed"
                    _rc=1
                fi
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
            _rc=1
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
    return $_rc
}

main "$@"
