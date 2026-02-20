#!/usr/bin/env bash
# autopilot-watch.sh — Read-only terminal dashboard for the autopilot pipeline.
# Run in a SEPARATE terminal; polls status files written by autopilot.
# Deps: bash >=4, jq, tput
set -euo pipefail

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: bash >= 4 required (found ${BASH_VERSION})" >&2; exit 1
fi

# ─── Colors (match autopilot-lib.sh) ─────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ─── Constants & Globals ─────────────────────────────────────────────────────
PHASES=(specify clarify clarify-verify plan tasks analyze analyze-verify implement review merge crystallize)
SPINNER_CHARS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
POLL_INTERVAL=1; MIN_COLS=40; MIN_ROWS=20
REPO_ROOT=""; STATUS_FILE=""; EVENTS_FILE=""
SPIN_IDX=0; TERM_ROWS=24; TERM_COLS=80; ALT_SCREEN_ACTIVE=false
STATUS_EPIC=""; STATUS_PHASE=""; STATUS_COST=""; STATUS_TOKENS_IN=""
STATUS_TOKENS_OUT=""; STATUS_LAST_TOOL=""; STATUS_PID=""; STATUS_LAST_ACTIVITY=""
IMPL_CURRENT_PHASE=""; IMPL_TOTAL_PHASES=""; IMPL_TASKS_COMPLETE=""; IMPL_TASKS_REMAINING=""
EPIC_TITLE=""
TIMELINE_PHASES=(); TIMELINE_DURATIONS=(); TIMELINE_COSTS=(); TIMELINE_ITERS=()
ACTIVITY_TIMES=(); ACTIVITY_TOOLS=(); ACTIVITY_TARGETS=()

# ─── Helpers ──────────────────────────────────────────────────────────────────
safe_tput() { tput "$@" 2>/dev/null || true; }
now_epoch() { date +%s 2>/dev/null || echo 0; }

format_duration() {
    local secs="${1:-0}"
    if [[ "$secs" -lt 60 ]]; then
        printf "%ds" "$secs"
    elif [[ "$secs" -lt 3600 ]]; then
        printf "%dm%02ds" $((secs / 60)) $((secs % 60))
    else
        printf "%dh%02dm" $((secs / 3600)) $(( (secs % 3600) / 60 ))
    fi
}

format_tokens() {
    local n="${1:-0}"
    if [[ "$n" -ge 1000 ]]; then
        printf "%dk" $((n / 1000))
    else
        printf "%d" "$n"
    fi
}

short_phase() {
    case "$1" in
        clarify-verify) echo "clarify-v" ;;
        analyze-verify) echo "analyze-v" ;;
        crystallize)    echo "crystal." ;;
        *)              echo "$1" ;;
    esac
}

iso_to_epoch() {
    local ts="$1"
    [[ -z "$ts" ]] && { echo 0; return; }
    # Strip timezone suffix for portable parsing
    local stripped="${ts%%[+-][0-9][0-9]:[0-9][0-9]}"
    stripped="${stripped%%Z}"
    # macOS (BSD date)
    date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" "+%s" 2>/dev/null \
        || date -d "$stripped" "+%s" 2>/dev/null \
        || echo 0
}

phase_start_epoch() {
    local phase="$1" epic="$2"
    local ts
    ts=$(tail -200 "$EVENTS_FILE" 2>/dev/null \
        | grep '"phase_start"' \
        | grep "\"$epic\"" \
        | grep "\"$phase\"" \
        | tail -1 \
        | jq -r '.ts // empty' 2>/dev/null) || true
    iso_to_epoch "$ts"
}

pid_alive() { local pid="${1:-}"; [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; }

# ─── Core functions ───────────────────────────────────────────────────────────
find_repo_root() {
    local dir
    dir="$(pwd)"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.specify/logs" ]]; then
            REPO_ROOT="$dir"
            STATUS_FILE="$dir/.specify/logs/autopilot-status.json"
            EVENTS_FILE="$dir/.specify/logs/events.jsonl"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    echo "ERROR: no .specify/logs/ found walking up from $(pwd)" >&2
    exit 1
}

cleanup() {
    stty echo 2>/dev/null
    [[ "$ALT_SCREEN_ACTIVE" == true ]] && { safe_tput rmcup; ALT_SCREEN_ACTIVE=false; }
    safe_tput cnorm
}

resize() {
    TERM_ROWS=$(tput lines 2>/dev/null) || TERM_ROWS=24
    TERM_COLS=$(tput cols 2>/dev/null) || TERM_COLS=80
}

read_status() {
    [[ ! -f "$STATUS_FILE" ]] && { STATUS_EPIC=""; STATUS_PID=""; return 1; }
    local parsed
    parsed=$(jq -r '[
        .epic // "", .phase // "", (.cost_usd // 0 | tostring),
        (.tokens.input // 0 | tostring), (.tokens.output // 0 | tostring),
        .last_tool // "", (.pid // "" | tostring), .last_activity_at // "",
        (.implement_progress.current_phase // "" | tostring),
        (.implement_progress.total_phases // "" | tostring),
        (.implement_progress.tasks_complete // "" | tostring),
        (.implement_progress.tasks_remaining // "" | tostring)
    ] | join("\t")' "$STATUS_FILE" 2>/dev/null) || return 1
    [[ -z "$parsed" ]] && return 1
    IFS=$'\t' read -r STATUS_EPIC STATUS_PHASE STATUS_COST STATUS_TOKENS_IN \
        STATUS_TOKENS_OUT STATUS_LAST_TOOL STATUS_PID STATUS_LAST_ACTIVITY \
        IMPL_CURRENT_PHASE IMPL_TOTAL_PHASES IMPL_TASKS_COMPLETE \
        IMPL_TASKS_REMAINING <<< "$parsed"
    return 0
}

read_phase_timeline() {
    TIMELINE_PHASES=() TIMELINE_DURATIONS=() TIMELINE_COSTS=() TIMELINE_ITERS=()
    [[ ! -f "$EVENTS_FILE" ]] && return
    [[ -z "$STATUS_EPIC" ]] && return

    local lines
    lines=$(tail -200 "$EVENTS_FILE" 2>/dev/null \
        | grep "\"${STATUS_EPIC}\"" \
        | grep -E '"phase_(start|end)"' 2>/dev/null) || return 0

    local -A phase_ends=() phase_starts=()
    local phase dur cost evt prev_dur prev_cost
    while IFS= read -r line; do
        evt=$(echo "$line" | jq -r '.event // ""' 2>/dev/null) || continue
        phase=$(echo "$line" | jq -r '.phase // ""' 2>/dev/null) || continue
        if [[ "$evt" == "phase_start" ]]; then
            phase_starts["$phase"]=$(( ${phase_starts["$phase"]:-0} + 1 ))
        elif [[ "$evt" == "phase_end" ]]; then
            dur=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null) || dur=0
            cost=$(echo "$line" | jq -r '.cost_usd // 0' 2>/dev/null) || cost=0
            # Accumulate across iterations (clarify/analyze may loop)
            prev_dur="${phase_ends["$phase,dur"]:-0}"
            prev_cost="${phase_ends["$phase,cost"]:-0}"
            phase_ends["$phase,dur"]=$(( prev_dur + dur ))
            phase_ends["$phase,cost"]=$(awk -v a="$prev_cost" -v b="$cost" 'BEGIN{printf "%.6f", a + b}' 2>/dev/null || echo "$cost")
        fi
    done <<< "$lines"

    for p in "${PHASES[@]}"; do
        if [[ -n "${phase_ends["$p,dur"]+x}" ]]; then
            TIMELINE_PHASES+=("$p")
            TIMELINE_DURATIONS+=("${phase_ends["$p,dur"]}")
            TIMELINE_COSTS+=("${phase_ends["$p,cost"]}")
            TIMELINE_ITERS+=("${phase_starts["$p"]:-1}")
        fi
    done
}

read_recent_activity() {
    ACTIVITY_TIMES=() ACTIVITY_TOOLS=() ACTIVITY_TARGETS=()
    [[ ! -f "$EVENTS_FILE" ]] && return

    # tool_use events don't carry an epic field — just grab recent ones
    local parsed
    parsed=$(tail -200 "$EVENTS_FILE" 2>/dev/null \
        | grep '"tool_use"' \
        | tail -10 \
        | jq -r '[.ts // "", .tool // "", (.target // "" | gsub("\n"; " "))] | join("\t")' 2>/dev/null) || return 0

    while IFS=$'\t' read -r ts tool target; do
        [[ -z "$ts" ]] && continue
        local time_part="${ts##*T}"
        time_part="${time_part%%[+-]*}"
        time_part="${time_part%%.*}"
        ACTIVITY_TIMES+=("${time_part:-??:??:??}")
        ACTIVITY_TOOLS+=("$tool")
        ACTIVITY_TARGETS+=("$target")
    done <<< "$parsed"
}

read_epic_title() {
    EPIC_TITLE=""
    [[ -z "$STATUS_EPIC" ]] && return
    local pattern="$REPO_ROOT/docs/specs/epics/epic-${STATUS_EPIC}-*.md"
    local f
    for f in $pattern; do
        [[ -f "$f" ]] || continue
        EPIC_TITLE=$(sed -n '/^title:/{ s/^title:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//; p; q; }' "$f" 2>/dev/null) || true
        break
    done
    [[ -z "$EPIC_TITLE" ]] && EPIC_TITLE="Epic $STATUS_EPIC"
}

# ─── Renderers ────────────────────────────────────────────────────────────────
render_header() {
    local title="AUTOPILOT · Epic ${STATUS_EPIC}: ${EPIC_TITLE}"
    local sub="Phase: ${STATUS_PHASE:-?}"
    # Detect model from events
    local model
    model=$(tail -50 "$EVENTS_FILE" 2>/dev/null \
        | grep '"session_init"' | tail -1 \
        | jq -r '.model // ""' 2>/dev/null) || model=""
    [[ -n "$model" ]] && sub="$sub ($model)"
    # Count phase_starts for current phase (iterations)
    local iter=1
    if [[ -f "$EVENTS_FILE" && -n "$STATUS_PHASE" ]]; then
        iter=$(tail -200 "$EVENTS_FILE" 2>/dev/null \
            | grep '"phase_start"' \
            | grep "\"$STATUS_PHASE\"" \
            | grep "\"${STATUS_EPIC}\"" \
            | wc -l 2>/dev/null) || iter=1
        [[ "$iter" -lt 1 ]] && iter=1
    fi
    sub="$sub · iter $iter"

    local w=$(( TERM_COLS - 6 )); [[ $w -lt 20 ]] && w=20
    local border; border=$(printf '─%.0s' $(seq 1 "$w"))
    printf "  ${CYAN}╭─%s─╮${RESET}\n" "$border"
    printf "  ${CYAN}│${RESET} ${BOLD}%-${w}s${RESET} ${CYAN}│${RESET}\n" "${title:0:$w}"
    printf "  ${CYAN}│${RESET} ${DIM}%-${w}s${RESET} ${CYAN}│${RESET}\n" "${sub:0:$w}"
    printf "  ${CYAN}╰─%s─╯${RESET}\n" "$border"
}

render_phases() {
    local -A completed=() completed_dur=() completed_cost=() completed_iter=()
    local i
    for i in "${!TIMELINE_PHASES[@]}"; do
        local p="${TIMELINE_PHASES[$i]}"
        completed["$p"]=1
        completed_dur["$p"]="${TIMELINE_DURATIONS[$i]}"
        completed_cost["$p"]="${TIMELINE_COSTS[$i]}"
        completed_iter["$p"]="${TIMELINE_ITERS[$i]}"
    done

    local spin="${SPINNER_CHARS[$SPIN_IDX]}"
    printf "\n"
    for p in "${PHASES[@]}"; do
        local label
        label=$(short_phase "$p")
        local line=""
        if [[ -n "${completed[$p]+x}" ]]; then
            local dur_s=$(( ${completed_dur[$p]:-0} / 1000 ))
            local dur_fmt
            dur_fmt=$(format_duration "$dur_s")
            local cost_fmt
            cost_fmt=$(printf "\$%.2f" "${completed_cost[$p]:-0}")
            local iter_info=""
            if [[ "${completed_iter[$p]:-1}" -gt 1 ]]; then
                iter_info="  ${completed_iter[$p]} iters"
            fi
            line=$(printf "  ${GREEN}✓${RESET} %-13s ${DIM}%7s    %-8s%s${RESET}" "$label" "$dur_fmt" "$cost_fmt" "$iter_info")
        elif [[ "$p" == "$STATUS_PHASE" ]]; then
            local live_dur=0
            local start_e
            start_e=$(phase_start_epoch "$p" "$STATUS_EPIC")
            if [[ "$start_e" -gt 0 ]]; then
                live_dur=$(( $(now_epoch) - start_e ))
            fi
            local dur_fmt
            dur_fmt=$(format_duration "$live_dur")
            local cost_fmt
            cost_fmt=$(printf "\$%.2f" "${STATUS_COST:-0}")
            line=$(printf "  ${CYAN}▶${RESET} ${CYAN}%-13s${RESET} %7s    %-8s   %s" "$label" "$dur_fmt" "$cost_fmt" "$spin")
        else
            line=$(printf "  ${DIM}○ %-13s${RESET}" "$label")
        fi
        printf "%s\n" "$line"
    done
}

render_costs() {
    local phase_cost="${STATUS_COST:-0}"
    local total_cost=0
    for c in "${TIMELINE_COSTS[@]}"; do
        total_cost=$(awk -v a="$total_cost" -v b="$c" 'BEGIN{printf "%.6f", a + b}' 2>/dev/null || echo "$total_cost")
    done
    if [[ -n "$STATUS_PHASE" ]]; then
        total_cost=$(awk -v a="$total_cost" -v b="$phase_cost" 'BEGIN{printf "%.6f", a + b}' 2>/dev/null || echo "$total_cost")
    fi

    local tok_in tok_out
    tok_in=$(format_tokens "${STATUS_TOKENS_IN:-0}")
    tok_out=$(format_tokens "${STATUS_TOKENS_OUT:-0}")

    local sep
    sep=$(printf '─%.0s' $(seq 1 $(( TERM_COLS - 4 )) ))
    printf "\n  ${DIM}── Cost %s${RESET}\n" "${sep:8}"
    printf "  Phase: ${BOLD}\$%.2f${RESET} · Total: ${BOLD}\$%.2f${RESET}\n" "$phase_cost" "$total_cost"
    printf "  Tokens: %s in / %s out\n" "$tok_in" "$tok_out"
}

render_activity() {
    local count=${#ACTIVITY_TIMES[@]}
    [[ $count -eq 0 ]] && return

    local sep
    sep=$(printf '─%.0s' $(seq 1 $(( TERM_COLS - 4 )) ))
    printf "\n  ${DIM}── Activity %s${RESET}\n" "${sep:12}"

    local max_target=$(( TERM_COLS - 22 ))
    [[ $max_target -lt 10 ]] && max_target=10

    # Reverse order (most recent first)
    local i
    for (( i = count - 1; i >= 0 && i >= count - 8; i-- )); do
        local t="${ACTIVITY_TIMES[$i]}"
        local tool="${ACTIVITY_TOOLS[$i]}"
        local target="${ACTIVITY_TARGETS[$i]}"
        # Truncate target
        if [[ ${#target} -gt $max_target ]]; then
            target="...${target: -$(( max_target - 3 ))}"
        fi
        printf "  ${DIM}%s${RESET}  ${YELLOW}%-6s${RESET} %s\n" "$t" "$tool" "$target"
    done
}

render_impl_progress() {
    [[ "$STATUS_PHASE" != "implement" ]] && return
    [[ -z "$IMPL_TOTAL_PHASES" || "$IMPL_TOTAL_PHASES" == "null" ]] && return

    local sep
    sep=$(printf '─%.0s' $(seq 1 $(( TERM_COLS - 4 )) ))
    printf "\n  ${DIM}── Implement Progress %s${RESET}\n" "${sep:22}"

    local done_n="${IMPL_TASKS_COMPLETE:-0}"
    local rem_n="${IMPL_TASKS_REMAINING:-0}"
    local total=$(( done_n + rem_n ))
    local pct=0
    [[ $total -gt 0 ]] && pct=$(( done_n * 100 / total ))

    printf "  Phase %s/%s · %s done / %s remaining\n" \
        "${IMPL_CURRENT_PHASE:-?}" "${IMPL_TOTAL_PHASES:-?}" "$done_n" "$rem_n"

    # Progress bar
    local bar_w=$(( TERM_COLS - 12 ))
    [[ $bar_w -lt 10 ]] && bar_w=10
    [[ $bar_w -gt 40 ]] && bar_w=40
    local filled=$(( bar_w * pct / 100 ))
    local empty=$(( bar_w - filled ))
    local bar=""
    local j
    for (( j = 0; j < filled; j++ )); do bar+="█"; done
    for (( j = 0; j < empty; j++ )); do bar+="░"; done
    printf "  ${GREEN}[%s]${RESET} %d%%\n" "$bar" "$pct"
}

render_waiting() {
    local spin="${SPINNER_CHARS[$SPIN_IDX]}"
    printf "\n\n"
    printf "  ${DIM}%s Waiting for autopilot...${RESET}\n" "$spin"
    printf "\n  ${DIM}Watching: %s${RESET}\n" "$STATUS_FILE"
}

render_frame() {
    local frame=""

    # Check terminal size
    if [[ "$TERM_ROWS" -lt "$MIN_ROWS" || "$TERM_COLS" -lt "$MIN_COLS" ]]; then
        frame=$(printf "\n  ${YELLOW}Terminal too small (%dx%d)${RESET}\n  Need at least %dx%d\n" \
            "$TERM_COLS" "$TERM_ROWS" "$MIN_COLS" "$MIN_ROWS")
        safe_tput cup 0 0
        printf '%b\n' "$frame"
        return
    fi

    if ! read_status || [[ -z "$STATUS_EPIC" ]]; then
        frame=$(render_waiting)
        safe_tput cup 0 0
        printf '%b\n' "$frame"
        return
    fi

    # Check if autopilot pid is alive
    if [[ -n "$STATUS_PID" ]] && ! pid_alive "$STATUS_PID"; then
        # PID gone — check staleness (>30s since last activity)
        local now_s
        now_s=$(now_epoch)
        local last_s=0
        if [[ -n "$STATUS_LAST_ACTIVITY" ]]; then
            last_s=$(iso_to_epoch "$STATUS_LAST_ACTIVITY")
        fi
        if [[ $(( now_s - last_s )) -gt 30 ]]; then
            frame=$(render_waiting)
            safe_tput cup 0 0
            printf '%b\n' "$frame"
            return
        fi
    fi

    read_epic_title
    read_phase_timeline
    read_recent_activity

    # Build frame from sub-renderers
    frame=""
    frame+=$(printf "\n")
    frame+=$(render_header)
    frame+=$(render_phases)
    frame+=$(render_costs)
    frame+=$(render_activity)
    frame+=$(render_impl_progress)

    # Pad remaining lines to clear old content
    local line_count
    line_count=$(echo -e "$frame" | wc -l)
    local remaining=$(( TERM_ROWS - line_count - 1 ))
    local k
    for (( k = 0; k < remaining; k++ )); do
        frame+=$(printf "\n$(safe_tput el)")
    done

    safe_tput cup 0 0
    echo -e "$frame"
}

show_help() {
    cat <<'USAGE'
Usage: autopilot-watch.sh [--help]

Read-only terminal dashboard for speckit autopilot. Run in a separate terminal.
Polls .specify/logs/ for autopilot-status.json and events.jsonl.

Options:  --help  Show this message
Requires: bash >= 4, jq, tput (ncurses)
USAGE
    exit 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in --help|-h) show_help ;; esac
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required but not found" >&2; exit 1
    fi
    find_repo_root; resize
    safe_tput smcup; ALT_SCREEN_ACTIVE=true; safe_tput civis
    stty -echo 2>/dev/null
    trap cleanup EXIT INT TERM
    trap resize WINCH
    while true; do
        render_frame
        SPIN_IDX=$(( (SPIN_IDX + 1) % ${#SPINNER_CHARS[@]} ))
        read -s -t 1 -n 1024 discard 2>/dev/null || true
    done
}

main "$@"
