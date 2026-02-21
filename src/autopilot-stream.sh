#!/usr/bin/env bash
# autopilot-stream.sh — NDJSON stream processor for autopilot observability.
#
# Processes `claude -p --output-format stream-json --verbose` output.
# Extracts tool_use events, token/cost metrics, and result text.
#
# Outputs:
#   .specify/logs/events.jsonl       — structured event stream
#   .specify/logs/{epic}-{phase}.log — full result text per phase
#   .specify/logs/autopilot-status.json — pollable live state
#   stdout                           — live dashboard (unless SILENT=true)
#
# Requires: jq, bash 4+
# Sourced by autopilot.sh — not run standalone.

set -euo pipefail

# ─── Accumulated Metrics ────────────────────────────────────────────────────

_accumulated_cost=0
_accumulated_input=0
_accumulated_output=0
_last_tool=""
_impl_progress_cache="{}"
_impl_tasks_mtime=""

# ─── Main Stream Processor ─────────────────────────────────────────────────

# Read NDJSON from stdin, dispatch by event type.
process_stream() {
    local epic="$1" phase="$2"
    local log_dir="$REPO_ROOT/.specify/logs"
    local events_log="$log_dir/events.jsonl"
    local phase_log="$log_dir/${epic}-${phase}.log"
    local status_file="$REPO_ROOT/.specify/logs/autopilot-status.json"
    mkdir -p "$log_dir"

    # Reset accumulators
    _accumulated_cost=0
    _accumulated_input=0
    _accumulated_output=0
    _last_tool=""

    # Emit phase_start event
    _emit_event "$events_log" "phase_start" \
        "$(jq -nc --arg e "$epic" --arg p "$phase" --arg m "${PHASE_MODEL[$phase]:-unknown}" \
        '{epic:$e, phase:$p, model:$m}')"

    # Eager status write before blocking on NDJSON
    _update_status "$status_file" "$epic" "$phase"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local event_type
        event_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || continue
        [[ -z "$event_type" ]] && continue

        case "$event_type" in
            system)
                _process_system_event "$events_log" "$status_file" "$epic" "$phase" "$line"
                ;;
            assistant)
                _process_assistant_event "$events_log" "$status_file" "$epic" "$phase" "$line"
                ;;
            user)
                _process_tool_result "$events_log" "$line"
                ;;
            result)
                _process_result "$events_log" "$phase_log" "$status_file" "$epic" "$phase" "$line"
                ;;
            # stream_event — intentionally discarded (redundant with result)
        esac
    done
}

# ─── Event Emitter ──────────────────────────────────────────────────────────

_emit_event() {
    local events_log="$1" event_name="$2" extra_json="$3"
    local ts
    ts="$(date -Iseconds)"
    echo "$extra_json" | jq -c --arg ts "$ts" --arg ev "$event_name" \
        '. + {ts: $ts, event: $ev}' >> "$events_log"
}

# ─── Event Handlers ─────────────────────────────────────────────────────────

_process_system_event() {
    local events_log="$1" status_file="$2" epic="$3" phase="$4" line="$5"

    local model session_id
    model=$(echo "$line" | jq -r '.model // "unknown"' 2>/dev/null)
    session_id=$(echo "$line" | jq -r '.session_id // ""' 2>/dev/null)

    _emit_event "$events_log" "session_init" \
        "$(jq -nc --arg m "$model" --arg sid "$session_id" '{model:$m, session_id:$sid}')"

    _update_status "$status_file" "$epic" "$phase"
}

_process_assistant_event() {
    local events_log="$1" status_file="$2" epic="$3" phase="$4" line="$5"

    # Extract tool_use blocks from content array
    local tool_uses
    tool_uses=$(echo "$line" | jq -c \
        '[.message.content[]? | select(.type=="tool_use") | {name, input}]' 2>/dev/null)

    local count
    count=$(echo "$tool_uses" | jq 'length' 2>/dev/null || echo 0)

    local i=0
    while [[ $i -lt $count ]]; do
        local tu
        tu=$(echo "$tool_uses" | jq -c ".[$i]")
        local tool_name target
        tool_name=$(echo "$tu" | jq -r '.name // "unknown"')
        target=$(echo "$tu" | jq -r '
            .input.file_path //
            .input.command //
            .input.pattern //
            .input.description //
            .input.skill //
            .input.prompt //
            ""' | tr '\n' ' ' | head -c 200)

        _emit_event "$events_log" "tool_use" \
            "$(jq -nc --arg t "$tool_name" --arg tgt "$target" '{tool:$t, target:$tgt}')"

        _last_tool="$tool_name ${target:0:80}"
        _update_status "$status_file" "$epic" "$phase"

        if [[ "${SILENT:-false}" != "true" ]]; then
            printf "  ${DIM}%s${RESET}  ${BOLD}%s${RESET} — %s\n" \
                "$(date +%H:%M:%S)" "$tool_name" "${target:0:60}"
        fi

        i=$((i + 1))
    done

    # Accumulate token usage
    local in_tok out_tok cache_tok
    in_tok=$(echo "$line" | jq '.message.usage.input_tokens // 0' 2>/dev/null || echo 0)
    out_tok=$(echo "$line" | jq '.message.usage.output_tokens // 0' 2>/dev/null || echo 0)
    cache_tok=$(echo "$line" | jq '.message.usage.cache_read_input_tokens // 0' 2>/dev/null || echo 0)
    _accumulated_input=$((_accumulated_input + in_tok + cache_tok))
    _accumulated_output=$((_accumulated_output + out_tok))
}

_process_tool_result() {
    local events_log="$1" line="$2"

    local is_error truncated_output
    is_error=$(echo "$line" | jq -r '.message.content[0].is_error // false' 2>/dev/null)
    truncated_output=$(echo "$line" | jq -r \
        '.tool_use_result // .message.content[0].content // ""' 2>/dev/null | head -c 200)

    if [[ "$is_error" == "true" ]]; then
        _emit_event "$events_log" "tool_error" \
            "$(jq -nc --arg out "$truncated_output" '{output:$out}')"

        if [[ "${SILENT:-false}" != "true" ]]; then
            printf "  ${DIM}%s${RESET}  ${RED}ERROR${RESET} — %s\n" \
                "$(date +%H:%M:%S)" "${truncated_output:0:60}"
        fi
    fi
}

_process_result() {
    local events_log="$1" phase_log="$2" status_file="$3" epic="$4" phase="$5" line="$6"

    local duration cost result_text stop_reason
    duration=$(echo "$line" | jq '.duration_ms // 0' 2>/dev/null)
    cost=$(echo "$line" | jq '.total_cost_usd // 0' 2>/dev/null)
    result_text=$(echo "$line" | jq -r '.result // ""' 2>/dev/null)
    stop_reason=$(echo "$line" | jq -r '.stop_reason // "unknown"' 2>/dev/null)

    _accumulated_cost=$(echo "$_accumulated_cost $cost" | awk '{printf "%.6f", $1 + $2}')

    _emit_event "$events_log" "phase_end" \
        "$(jq -nc --arg e "$epic" --arg p "$phase" --arg sr "$stop_reason" \
        --argjson dur "${duration:-0}" --argjson cost "${cost:-0}" \
        --argjson ti "$_accumulated_input" --argjson to "$_accumulated_output" \
        '{epic:$e, phase:$p, duration_ms:$dur, cost_usd:$cost, stop_reason:$sr,
          tokens:{input:$ti, output:$to}}')"

    echo "$result_text" > "$phase_log"
    _update_status "$status_file" "$epic" "$phase"

    if [[ "${SILENT:-false}" != "true" ]]; then
        local dur_min
        dur_min=$(echo "$duration" | awk '{printf "%.1f", $1/60000}')
        printf "\n  ${GREEN}${BOLD}Phase %s complete${RESET} — %sm, \$%.4f (%dk in / %dk out)\n\n" \
            "$phase" "$dur_min" "$cost" \
            "$((_accumulated_input / 1000))" "$((_accumulated_output / 1000))"
    fi
}

# ─── Implement Progress (cached) ────────────────────────────────────────

# Return implement progress JSON, re-reading tasks.md only when mtime changes.
_get_impl_progress() {
    local epic="$1"

    # Find tasks file for this epic
    local tasks_file=""
    for d in "$REPO_ROOT"/specs/"${epic}"-*; do
        [[ -f "$d/tasks.md" ]] && tasks_file="$d/tasks.md" && break
    done
    if [[ -z "$tasks_file" ]]; then
        echo "{}"
        return
    fi

    local current_mtime
    current_mtime=$(stat -c %Y "$tasks_file" 2>/dev/null || stat -f %m "$tasks_file" 2>/dev/null || echo 0)

    if [[ "$current_mtime" != "$_impl_tasks_mtime" ]]; then
        _impl_tasks_mtime="$current_mtime"
        local cur total inc comp
        cur=$(get_current_impl_phase "$tasks_file")
        total=$(count_phases "$tasks_file")
        inc=$(grep -c '^\- \[ \]' "$tasks_file" 2>/dev/null || echo 0)
        comp=$(grep -c '^\- \[x\]' "$tasks_file" 2>/dev/null || echo 0)
        _impl_progress_cache=$(jq -nc \
            --argjson cp "${cur:-0}" --argjson tp "${total:-0}" \
            --argjson ic "${inc:-0}" --argjson cc "${comp:-0}" \
            '{current_phase:$cp, total_phases:$tp, tasks_complete:$cc, tasks_remaining:$ic}')
    fi
    echo "$_impl_progress_cache"
}

# ─── Status File ────────────────────────────────────────────────────────────

_update_status() {
    local status_file="$1" epic="$2" phase="$3"
    local tmp="${status_file}.tmp"

    # Include implement progress when in implement phase
    local impl_json="{}"
    if [[ "$phase" == "implement" ]]; then
        impl_json=$(_get_impl_progress "$epic")
    fi

    jq -n \
        --arg epic "$epic" \
        --arg phase "$phase" \
        --arg ts "$(date -Iseconds)" \
        --arg tool "${_last_tool:-}" \
        --argjson cost "${_accumulated_cost:-0}" \
        --argjson ti "${_accumulated_input:-0}" \
        --argjson to "${_accumulated_output:-0}" \
        --argjson pid "$$" \
        --argjson impl "$impl_json" \
        '{
            epic: $epic,
            phase: $phase,
            last_activity_at: $ts,
            last_tool: $tool,
            cost_usd: $cost,
            tokens: {input: $ti, output: $to},
            pid: $pid,
            implement_progress: $impl
        }' > "$tmp" 2>/dev/null && mv "$tmp" "$status_file" 2>/dev/null || true
}

# ─── Dashboard Header ──────────────────────────────────────────────────────

_print_dashboard_header() {
    local epic="$1" title="$2" phase="$3" model="$4"
    [[ "${SILENT:-false}" == "true" ]] && return 0
    echo ""
    printf "  ${BOLD}╔══════════════════════════════════════════════════════╗${RESET}\n"
    printf "  ${BOLD}║${RESET}  Epic %s: %s\n" "$epic" "$title"
    printf "  ${BOLD}║${RESET}  Phase: ${CYAN}%s${RESET} (%s)\n" "$phase" "$model"

    # Show task progress for implement phase
    if [[ "$phase" == "implement" ]]; then
        local prog
        prog=$(_get_impl_progress "$epic")
        local comp rem cur tot
        comp=$(echo "$prog" | jq '.tasks_complete // 0')
        rem=$(echo "$prog" | jq '.tasks_remaining // 0')
        cur=$(echo "$prog" | jq '.current_phase // 0')
        tot=$(echo "$prog" | jq '.total_phases // 0')
        if [[ "$tot" -gt 0 ]]; then
            printf "  ${BOLD}║${RESET}  Tasks: ${GREEN}%d done${RESET} / ${YELLOW}%d remaining${RESET} (phase %s/%s)\n" \
                "$comp" "$rem" "$cur" "$tot"
        fi
    fi

    printf "  ${BOLD}╚══════════════════════════════════════════════════════╝${RESET}\n"
    echo ""
}
