#!/usr/bin/env bash
# autopilot-lib.sh — Shared functions for the autopilot orchestrator
# State detection, epic selection, logging, verification — all pure bash.

set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Logging ─────────────────────────────────────────────────────────────────

AUTOPILOT_LOG=""

init_logging() {
    local repo_root="$1"
    local log_dir="$repo_root/.specify/logs"
    mkdir -p "$log_dir"
    AUTOPILOT_LOG="$log_dir/autopilot.log"
}

log() {
    local level="$1" msg="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$timestamp] [$level] $msg"

    # Write to log file
    if [[ -n "$AUTOPILOT_LOG" ]]; then
        echo "$line" >> "$AUTOPILOT_LOG"
    fi

    # Print to terminal with color
    case "$level" in
        INFO)  echo -e "${BLUE}[autopilot]${RESET} $msg" ;;
        OK)    echo -e "${GREEN}[autopilot]${RESET} $msg" ;;
        WARN)  echo -e "${YELLOW}[autopilot]${RESET} $msg" ;;
        ERROR) echo -e "${RED}[autopilot]${RESET} $msg" ;;
        PHASE) echo -e "${CYAN}${BOLD}[autopilot]${RESET} ${BOLD}$msg${RESET}" ;;
        *)     echo -e "[autopilot] $msg" ;;
    esac
}

# ─── Epic Discovery ─────────────────────────────────────────────────────────

# List all epics from docs/specs/epics/ with their metadata.
# Output: lines of "epic_id|status|short_name|title|epic_file"
list_epics() {
    local repo_root="$1"
    local epics_dir="$repo_root/docs/specs/epics"

    [[ ! -d "$epics_dir" ]] && return

    for epic_file in "$epics_dir"/epic-*.md; do
        [[ ! -f "$epic_file" ]] && continue

        local epic_id="" status="" title="" branch=""

        # Parse YAML frontmatter
        local in_frontmatter=false
        while IFS= read -r line; do
            if [[ "$line" == "---" ]]; then
                if $in_frontmatter; then break; fi
                in_frontmatter=true
                continue
            fi
            if $in_frontmatter; then
                if [[ "$line" =~ ^epic_id:\ *(.+) ]]; then
                    epic_id="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^status:\ *(.+) ]]; then
                    status="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ ^branch:\ *(.+) ]]; then
                    branch="${BASH_REMATCH[1]}"
                fi
            fi
        done < "$epic_file"

        # Extract title from first "# Epic: ..." heading
        title=$(grep -m1 '^# Epic:' "$epic_file" | sed 's/^# Epic: *//' || true)

        # Derive epic number (e.g., "003" from "epic-003")
        local num="${epic_id#epic-}"

        # Use branch field as short_name (the spec dir name = branch name)
        local short_name="${branch:-}"

        echo "${num}|${status}|${short_name}|${title}|${epic_file}"
    done
}

# Find a .pen design file for the given epic number.
# Searches docs/specs/epics/ for epic-NNN-*.pen (co-located with epic MDs).
# Output: absolute path to .pen file, or empty if none found.
find_pen_file() {
    local repo_root="$1" epic_num="$2"
    for f in "${repo_root}/docs/specs/epics/epic-${epic_num}"-*.pen; do
        [[ -f "$f" ]] && echo "$f" && return
    done
}

# Check if an epic has been merged to the base branch.
# Accepts status from YAML as primary signal, falls back to git log.
is_epic_merged() {
    local repo_root="$1"
    local short_name="$2"
    local yaml_status="${3:-}"

    # Primary: check YAML status field
    if [[ "$yaml_status" == "merged" ]]; then
        return 0
    fi

    [[ -z "$short_name" ]] && return 1

    # Fallback: check git log for merge commits — check MERGE_TARGET first, then BASE_BRANCH
    # Note: avoid `grep -q` in a pipeline with pipefail — grep -q exits early,
    # causing SIGPIPE on the upstream command, which pipefail reports as failure.
    local check_branches="${MERGE_TARGET:-${BASE_BRANCH:-master}}"
    [[ "${MERGE_TARGET:-}" != "${BASE_BRANCH:-}" ]] && check_branches="$check_branches ${BASE_BRANCH:-master}"
    local merge_match=""
    for check_branch in $check_branches; do
        merge_match="$(git -C "$repo_root" log "$check_branch" --oneline 2>/dev/null \
            | grep -i "merge.*${short_name}" || true)"
        [[ -n "$merge_match" ]] && return 0
    done
    return 1
}

# Find the next epic that needs work.
# Returns: "num|short_name|title|epic_file" or empty if all done.
find_next_epic() {
    local repo_root="$1"
    local target_epic="${2:-}"  # Optional: specific epic number to target

    while IFS='|' read -r num status short_name title epic_file; do
        [[ -z "$num" ]] && continue

        # If targeting a specific epic, skip others
        if [[ -n "$target_epic" ]]; then
            if [[ "$num" != "$target_epic" ]]; then
                continue
            fi
            echo "${num}|${short_name}|${title}|${epic_file}"
            return
        fi

        # Skip merged epics
        if is_epic_merged "$repo_root" "$short_name" "$status"; then
            continue
        fi

        echo "${num}|${short_name}|${title}|${epic_file}"
        return
    done < <(list_epics "$repo_root" | sort -t'|' -k1,1)
}

# ─── State Detection ────────────────────────────────────────────────────────

# Detect the current lifecycle phase for an epic. Pure filesystem checks.
# Output: one of: specify, clarify, plan, design-read, tasks, analyze, implement, review, done
# Note: clarify and analyze are iterative — they loop until convergence markers
# (<!-- CLARIFY_COMPLETE --> and <!-- ANALYZED -->) are present.
detect_state() {
    local repo_root="$1"
    local epic_num="$2"
    local short_name="$3"
    local spec_dir="$repo_root/specs/$short_name"

    # No spec dir or no spec.md → need to specify
    if [[ -z "$short_name" ]] || [[ ! -f "$spec_dir/spec.md" ]]; then
        echo "specify"
        return
    fi

    # Always run clarify until explicitly marked complete (iterative phase)
    if ! grep -q '<!-- CLARIFY_COMPLETE -->' "$spec_dir/spec.md" 2>/dev/null; then
        echo "clarify"
        return
    fi

    # Clarify marked complete — verify independently before proceeding
    if ! grep -q '<!-- CLARIFY_VERIFIED -->' "$spec_dir/spec.md" 2>/dev/null; then
        echo "clarify-verify"
        return
    fi

    # No plan → need to plan
    if [[ ! -f "$spec_dir/plan.md" ]]; then
        echo "plan"
        return
    fi

    # No tasks → check if design extraction is needed first
    if [[ ! -f "$spec_dir/tasks.md" ]]; then
        local pen_file
        pen_file="$(find_pen_file "$repo_root" "$epic_num")"
        if [[ -n "$pen_file" ]]; then
            if [[ ! -f "$spec_dir/design-context.md" ]]; then
                echo "design-read"
                return
            fi
            # Re-extract if .pen is newer than design-context.md
            if [[ "$pen_file" -nt "$spec_dir/design-context.md" ]]; then
                echo "design-read"
                return
            fi
        fi
        echo "tasks"
        return
    fi

    # Tasks exist but not analyzed yet — iterative analysis until zero findings
    if ! grep -q '<!-- ANALYZED -->' "$spec_dir/tasks.md" 2>/dev/null; then
        echo "analyze"
        return
    fi

    # Count incomplete vs complete tasks
    local incomplete complete
    incomplete=$(grep -ci '^\- \[ \]' "$spec_dir/tasks.md" 2>/dev/null || true)
    complete=$(grep -ci '^\- \[x\]' "$spec_dir/tasks.md" 2>/dev/null || true)
    incomplete="${incomplete:-0}"
    complete="${complete:-0}"

    if [[ "$incomplete" -gt 0 ]]; then
        echo "implement"
        return
    fi

    if [[ "$complete" -gt 0 ]]; then
        # All tasks done — check if already merged
        if is_epic_merged "$repo_root" "$short_name"; then
            echo "done"
        else
            echo "review"
        fi
        return
    fi

    # Edge case: tasks.md exists but no checkboxes found
    echo "tasks"
}

# ─── Implementation Phase Parsing ───────────────────────────────────────────

# Get the current (first incomplete) implementation phase number from tasks.md.
# Output: phase number (e.g., "3") or empty if no incomplete phases.
get_current_impl_phase() {
    local tasks_file="$1"

    [[ ! -f "$tasks_file" ]] && return

    local current_phase=""
    local found_incomplete=false

    while IFS= read -r line; do
        # Match phase headers like "## Phase 3" or "### Phase 3:"
        if [[ "$line" =~ ^##[#]?\ *Phase\ ([0-9]+) ]]; then
            current_phase="${BASH_REMATCH[1]}"
        fi

        # If we're in a phase and find an incomplete task, that's our phase
        if [[ -n "$current_phase" ]] && [[ "$line" =~ ^-\ \[\ \] ]]; then
            echo "$current_phase"
            return
        fi
    done < "$tasks_file"
}

# Count total phases in tasks.md.
count_phases() {
    local tasks_file="$1"
    [[ ! -f "$tasks_file" ]] && echo "0" && return
    grep -c '^##[#]*\ *Phase\ [0-9]' "$tasks_file" 2>/dev/null || echo "0"
}

# Count incomplete tasks in a specific phase.
count_phase_incomplete() {
    local tasks_file="$1"
    local target_phase="$2"
    local in_phase=false
    local count=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^##[#]?\ *Phase\ ([0-9]+) ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$target_phase" ]]; then
                in_phase=true
            elif $in_phase; then
                break  # Left target phase
            fi
        fi
        if $in_phase && [[ "$line" =~ ^-\ \[\ \] ]]; then
            count=$((count + 1))
        fi
    done < "$tasks_file"

    echo "$count"
}

# ─── Branch Management ──────────────────────────────────────────────────────

# Ensure we're on the correct feature branch for an epic.
ensure_feature_branch() {
    local repo_root="$1"
    local short_name="$2"

    if [[ -z "$short_name" ]]; then
        return 0  # Will be created by specify phase
    fi

    local current
    current=$(git -C "$repo_root" branch --show-current 2>/dev/null || echo "")

    if [[ "$current" != "$short_name" ]]; then
        # Check if branch exists
        if git -C "$repo_root" rev-parse --verify "$short_name" >/dev/null 2>&1; then
            log INFO "Switching to branch $short_name"
            git -C "$repo_root" checkout "$short_name"
        else
            log WARN "Branch $short_name does not exist yet (will be created by specify)"
        fi
    fi
}

# ─── Post-Merge Automation ─────────────────────────────────────────────

# Update epic YAML frontmatter to status: merged and set branch field.
mark_epic_merged() {
    local epic_file="$1" short_name="$2"

    [[ ! -f "$epic_file" ]] && return 1

    sed "s/^status: .*/status: merged/" "$epic_file" > "${epic_file}.tmp" && mv "${epic_file}.tmp" "$epic_file"
    sed "s/^branch:.*/branch: $short_name/" "$epic_file" > "${epic_file}.tmp" && mv "${epic_file}.tmp" "$epic_file"

    log INFO "Updated $(basename "$epic_file"): status=merged, branch=$short_name"
}

# Write a summary report after a successful epic merge.
# Reads phase_end events from events.jsonl for cost/duration breakdown.
write_epic_summary() {
    local repo_root="$1" epic_num="$2" short_name="$3" title="$4" epic_total_cost="$5"
    local log_dir="$repo_root/.specify/logs"
    local summary_file="$log_dir/${epic_num}-summary.md"
    local events_log="$log_dir/events.jsonl"
    mkdir -p "$log_dir"

    local files_changed test_output lint_output
    # Use the most recent merge commit to count feature branch files
    local merge_sha
    merge_sha=$(git -C "$repo_root" log --merges -1 --format=%H 2>/dev/null || true)
    if [[ -n "$merge_sha" ]]; then
        files_changed=$(git -C "$repo_root" diff --name-only "${merge_sha}^..${merge_sha}" 2>/dev/null | wc -l || echo 0)
    else
        files_changed=$(git -C "$repo_root" diff --name-only HEAD~1..HEAD 2>/dev/null | wc -l || echo 0)
    fi
    if [[ -n "$PROJECT_TEST_CMD" ]]; then
        test_output=$(cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_TEST_CMD" 2>&1 | tail -3 || echo "no tests")
    else
        test_output="(no test command configured)"
    fi
    if [[ -n "$PROJECT_LINT_CMD" ]]; then
        lint_output=$(cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_LINT_CMD" 2>&1 | tail -1 || echo "no lint")
    else
        lint_output="(no lint command configured)"
    fi

    # Build per-phase table from events.jsonl
    local phase_table=""
    if [[ -f "$events_log" ]]; then
        while IFS= read -r event_line; do
            local phase dur cost
            phase=$(echo "$event_line" | jq -r '.phase')
            dur=$(echo "$event_line" | jq '.duration_ms // 0')
            cost=$(echo "$event_line" | jq '.cost_usd // 0')
            local dur_min
            dur_min=$(echo "$dur" | awk '{printf "%.1f", $1/60000}')
            phase_table+="| $phase | ${dur_min}m | \$${cost} |"$'\n'
        done < <(jq -c "select(.event==\"phase_end\" and .epic==\"$epic_num\")" "$events_log" 2>/dev/null)
    fi

    cat > "$summary_file" <<SUMMARY
# Epic $epic_num: $title

**Status**: Merged to $MERGE_TARGET
**Branch**: $short_name
**Files changed**: $files_changed
**Total cost**: \$$epic_total_cost
$(if [[ -n "${LAST_PR_NUMBER:-}" ]]; then echo "**PR**: #$LAST_PR_NUMBER"; fi)
$(if [[ -n "${LAST_CR_STATUS:-}" ]]; then echo "**CodeRabbit**: $LAST_CR_STATUS"; fi)

## Tests

\`\`\`
$test_output
\`\`\`

## Lint

\`\`\`
$lint_output
\`\`\`

## Phase Breakdown

| Phase | Duration | Cost |
|-------|----------|------|
$phase_table
*Generated by autopilot at $(date -Iseconds)*
SUMMARY

    log OK "Summary written: $summary_file"
}

# ─── Project Config ─────────────────────────────────────────────────────────

# Load project tooling config. Exits if project.env is missing (preflight gate).
load_project_config() {
    local repo_root="$1"
    local config_file="$repo_root/.specify/project.env"

    # Defaults
    PROJECT_TEST_CMD=""
    PROJECT_LINT_CMD=""
    PROJECT_WORK_DIR="."
    PROJECT_BUILD_CMD=""
    PROJECT_FORMAT_CMD=""
    BASE_BRANCH="master"
    FORCE_ADVANCE_ON_REVIEW_FAIL="false"
    PROJECT_PREFLIGHT_TOOLS=""

    if [[ ! -f "$config_file" ]]; then
        log ERROR "Missing .specify/project.env — autopilot cannot run without it."
        log ERROR "Create it manually or run: .specify/scripts/bash/autopilot-detect-project.sh"
        exit 1
    fi

    set -a; source "$config_file"; set +a
    log INFO "Loaded project config from $config_file"

    if [[ -z "$PROJECT_TEST_CMD" ]]; then
        log WARN "PROJECT_TEST_CMD is empty — test steps will be skipped"
    fi
    if [[ -z "$PROJECT_LINT_CMD" ]]; then
        log WARN "PROJECT_LINT_CMD is empty — lint steps will be skipped"
    fi
}

# ─── Merge Target Detection ──────────────────────────────────────────────────

# Detect merge target branch: staging if it exists, otherwise BASE_BRANCH.
# Convention-based — zero config.
detect_merge_target() {
    local repo_root="${1:-.}"
    if git -C "$repo_root" rev-parse --verify staging >/dev/null 2>&1 || \
       git -C "$repo_root" rev-parse --verify origin/staging >/dev/null 2>&1; then
        echo "staging"
    else
        echo "${BASE_BRANCH:-master}"
    fi
}

# ─── Verification ───────────────────────────────────────────────────────────

source "${SCRIPT_DIR}/autopilot-verify.sh"

verify_preflight_tools() {
    local repo_root="$1"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log INFO "[DRY RUN] Would verify preflight tools"
        return 0
    fi
    if [[ -z "${PROJECT_PREFLIGHT_TOOLS:-}" ]]; then
        log INFO "No preflight tools configured — skipping"
        return 0
    fi
    local -a missing=()
    for tool in $PROJECT_PREFLIGHT_TOOLS; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Missing preflight tools: ${missing[*]}"
        return 1
    fi
    log OK "All preflight tools available"
    return 0
}

# ─── Project Summary ──────────────────────────────────────────────────

# Aggregate all per-epic summaries into a single project-wide report.
write_project_summary() {
    local repo_root="$1"
    local log_dir="$repo_root/.specify/logs"
    local summary_file="$log_dir/project-summary.md"
    mkdir -p "$log_dir"

    local total_cost=0
    local total_files=0
    local epic_table=""

    for sf in "$log_dir"/[0-9][0-9][0-9]-summary.md; do
        [[ ! -f "$sf" ]] && continue
        local epic_name cost files
        epic_name=$(head -1 "$sf" | sed 's/^# //')
        cost=$(grep -o '\*\*Total cost\*\*.*\$[0-9.]*' "$sf" 2>/dev/null | grep -o '[0-9.]*$' || echo "0")
        cost="${cost:-0}"
        files=$(grep -o '\*\*Files changed\*\*:[[:space:]]*[0-9]*' "$sf" 2>/dev/null | grep -o '[0-9]*$' || echo "0")
        files="${files:-0}"
        total_cost=$(echo "$total_cost $cost" | awk '{printf "%.2f", $1 + $2}')
        total_files=$((total_files + files))
        epic_table+="| $epic_name | $files | \$$cost |"$'\n'
    done

    # Capture final test/lint state
    local test_summary lint_summary
    if [[ -n "$PROJECT_TEST_CMD" ]]; then
        test_summary=$(cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_TEST_CMD" 2>&1 | tail -3 || echo "failed")
    else
        test_summary="(no test command configured)"
    fi
    if [[ -n "$PROJECT_LINT_CMD" ]]; then
        lint_summary=$(cd "$repo_root/$PROJECT_WORK_DIR" && eval "$PROJECT_LINT_CMD" 2>&1 | tail -1 || echo "issues")
    else
        lint_summary="(no lint command configured)"
    fi

    cat > "$summary_file" <<SUMMARY
# Project Summary

**Total cost**: \$$total_cost
**Total files changed**: $total_files
**Generated**: $(date -Iseconds)

## Epics

| Epic | Files | Cost |
|------|-------|------|
$epic_table
## Final Tests

\`\`\`
$test_summary
\`\`\`

## Final Lint

\`\`\`
$lint_summary
\`\`\`

*Generated by autopilot finalize*
SUMMARY

    log OK "Project summary written: $summary_file"
}
