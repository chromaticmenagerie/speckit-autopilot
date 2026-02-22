#!/usr/bin/env bash
# autopilot-github-sync.sh — GitHub Projects sync operations.
# Issue creation, status updates, task sync, and resync.
# Sourced by autopilot-github.sh (not standalone).

# ─── JSON Helpers ───────────────────────────────────────────────────────────

# Init or return path to per-epic task-issues JSON.
_gh_task_json() {
    local repo_root="$1" epic_num="$2"
    local f="$repo_root/.specify/logs/${epic_num}-task-issues.json"
    if [[ ! -f "$f" ]]; then
        echo '{"epic":null,"tasks":{}}' > "$f"
    fi
    echo "$f"
}

# ─── Task Parsing ───────────────────────────────────────────────────────────

# Parse tasks.md into structured output: "key|checked|desc" per line.
# Usage: _gh_parse_tasks < tasks.md
# Output: P1.1| |Set up auth module\nP1.2|x|Define User model\n...
_gh_parse_tasks() {
    local current_phase="" task_counter=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[#]?\ *Phase\ ([0-9]+) ]]; then
            current_phase="${BASH_REMATCH[1]}"
            task_counter=0
            continue
        fi
        if [[ -n "$current_phase" ]] && [[ "$line" =~ ^-\ \[([\ x])\]\ (.+) ]]; then
            task_counter=$((task_counter + 1))
            local desc="${BASH_REMATCH[2]}"
            desc="${desc% \[P\]}"
            desc="${desc% [P]}"
            echo "P${current_phase}.${task_counter}|${BASH_REMATCH[1]}|${desc}"
        fi
    done
}

# ─── Epic Issues ────────────────────────────────────────────────────────────

# Create a GitHub issue for the epic and add it to the project.
# Idempotent: skips if epic already has an issue in the JSON.
gh_create_epic_issue() {
    $GH_ENABLED || return 0
    local repo_root="$1" epic_num="$2" title="$3"
    local json_file
    json_file=$(_gh_task_json "$repo_root" "$epic_num")

    # Skip if already created
    local existing
    existing=$(jq -r '.epic.url // empty' "$json_file" 2>/dev/null)
    if [[ -n "$existing" ]]; then
        return 0
    fi

    # Create epic label (idempotent)
    gh label create "epic:$epic_num" --repo "$GH_OWNER_REPO" --color "FBCA04" \
        --description "Epic $epic_num" 2>/dev/null || true

    local issue_url
    issue_url=$(gh_try "create epic issue" gh issue create \
        --repo "$GH_OWNER_REPO" \
        --title "[Epic $epic_num] $title" \
        --label "autopilot:epic,epic:$epic_num" \
        --assignee "$GH_USER" \
        --body "Epic $epic_num: $title

Managed by speckit-autopilot.") || return 1

    local item_json
    item_json=$(gh_try "add epic to project" gh project item-add "$GH_PROJECT_NUM" \
        --owner "$GH_OWNER" --url "$issue_url" --format json) || return 1

    local item_id
    item_id=$(echo "$item_json" | jq -r '.id')
    local issue_num="${issue_url##*/}"

    local tmp="${json_file}.tmp"
    jq --arg url "$issue_url" --arg item "$item_id" --arg num "$issue_num" \
        '.epic = {url:$url, item_id:$item, number:($num|tonumber)}' "$json_file" > "$tmp" && mv "$tmp" "$json_file"

    log OK "Created epic issue: [Epic $epic_num] $title (#$issue_num)"
}

# ─── Task Issues ────────────────────────────────────────────────────────────

# Parse tasks.md and create a GitHub issue per task. Adds all to the project.
# Idempotent: skips tasks already in the JSON.
gh_create_task_issues() {
    $GH_ENABLED || return 0
    local repo_root="$1" epic_num="$2" tasks_file="$3"
    [[ -f "$tasks_file" ]] || return 0

    local json_file
    json_file=$(_gh_task_json "$repo_root" "$epic_num")

    local epic_issue_num
    epic_issue_num=$(jq -r '.epic.number // empty' "$json_file" 2>/dev/null)

    local created=0

    while IFS='|' read -r key checked desc; do
        [[ -z "$key" ]] && continue

        local existing
        existing=$(jq -r --arg k "$key" '.tasks[$k].url // empty' "$json_file" 2>/dev/null)
        [[ -n "$existing" ]] && continue

        local task_title="[${epic_num}-${key}] $desc"
        local task_body="Part of [Epic $epic_num]"
        [[ -n "$epic_issue_num" ]] && task_body="$task_body #$epic_issue_num"

        local issue_url
        issue_url=$(gh_try "create task issue $key" gh issue create \
            --repo "$GH_OWNER_REPO" \
            --title "$task_title" \
            --label "autopilot:task,epic:$epic_num" \
            --assignee "$GH_USER" \
            --body "$task_body") || continue

        local item_json
        item_json=$(gh_try "add task $key to project" gh project item-add "$GH_PROJECT_NUM" \
            --owner "$GH_OWNER" --url "$issue_url" --format json) || continue

        local item_id issue_num
        item_id=$(echo "$item_json" | jq -r '.id')
        issue_num="${issue_url##*/}"

        local tmp="${json_file}.tmp"
        jq --arg k "$key" --arg url "$issue_url" --arg item "$item_id" \
            --arg num "$issue_num" --arg title "$task_title" \
            '.tasks[$k] = {url:$url, item_id:$item, number:($num|tonumber), title:$title}' \
            "$json_file" > "$tmp" && mv "$tmp" "$json_file"

        created=$((created + 1))
    done < <(_gh_parse_tasks < "$tasks_file")

    if [[ $created -gt 0 ]]; then
        log OK "Created $created task issues for epic $epic_num"
        gh_update_epic_body "$repo_root" "$epic_num" "$tasks_file"
    fi
}

# ─── Status Updates ─────────────────────────────────────────────────────────

# Update a single item's status on the project board.
gh_update_status() {
    local item_id="$1" phase="$2"
    local status
    status=$(_gh_phase_to_status "$phase")
    local opt_id="${GH_STATUS_OPT[$status]:-}"

    [[ -z "$opt_id" ]] && return 1

    gh_try "update status → $status" gh project item-edit \
        --id "$item_id" --project-id "$GH_PROJECT_NODE_ID" \
        --field-id "$GH_FIELD_STATUS_ID" \
        --single-select-option-id "$opt_id" >/dev/null || return 1
}

# Rebuild epic issue body with linked task checklist from tasks.md state.
gh_update_epic_body() {
    $GH_ENABLED || return 0
    local repo_root="$1" epic_num="$2" tasks_file="$3"
    [[ -f "$tasks_file" ]] || return 0

    local json_file
    json_file=$(_gh_task_json "$repo_root" "$epic_num")

    local epic_url
    epic_url=$(jq -r '.epic.url // empty' "$json_file" 2>/dev/null)
    [[ -z "$epic_url" ]] && return 0

    local body="" last_phase="" total=0 done_count=0

    while IFS='|' read -r key checked desc; do
        [[ -z "$key" ]] && continue
        total=$((total + 1))

        # Insert phase header when phase changes
        local phase_num="${key#P}"
        phase_num="${phase_num%%.*}"
        if [[ "$phase_num" != "$last_phase" ]]; then
            body+=$'\n'"## Phase $phase_num"$'\n'
            last_phase="$phase_num"
        fi

        local issue_num
        issue_num=$(jq -r --arg k "$key" '.tasks[$k].number // empty' "$json_file" 2>/dev/null)

        local checkbox="[ ]"
        if [[ "$checked" == "x" ]]; then
            checkbox="[x]"
            done_count=$((done_count + 1))
        fi

        if [[ -n "$issue_num" ]]; then
            body+="- ${checkbox} [${epic_num}-${key}] ${desc} (#${issue_num})"$'\n'
        else
            body+="- ${checkbox} [${epic_num}-${key}] ${desc}"$'\n'
        fi
    done < <(_gh_parse_tasks < "$tasks_file")

    local full_body="Managed by speckit-autopilot.
${body}
---
*Progress: ${done_count}/${total} tasks complete*
*Updated: $(date -Iseconds)*"

    gh_try "update epic body" gh issue edit "$epic_url" --body "$full_body" >/dev/null || return 1
}

# ─── Phase Sync ─────────────────────────────────────────────────────────────

# Called at each phase transition. Updates epic status + syncs task completions.
gh_sync_phase() {
    $GH_ENABLED || return 0
    local repo_root="$1" epic_num="$2" phase="$3" tasks_file="$4"

    local json_file
    json_file=$(_gh_task_json "$repo_root" "$epic_num")

    # Update epic item status
    local epic_item_id
    epic_item_id=$(jq -r '.epic.item_id // empty' "$json_file" 2>/dev/null)
    # Non-fatal: sync failures don't block pipeline (gh_try logs errors)
    [[ -n "$epic_item_id" ]] && gh_update_status "$epic_item_id" "$phase" || true

    # During implement: sync task completions
    if [[ "$phase" == "implement" ]] && [[ -f "$tasks_file" ]]; then
        while IFS='|' read -r key checked desc; do
            [[ -z "$key" ]] && continue
            [[ "$checked" != "x" ]] && continue

            local task_url task_item_id
            task_url=$(jq -r --arg k "$key" '.tasks[$k].url // empty' "$json_file" 2>/dev/null)
            task_item_id=$(jq -r --arg k "$key" '.tasks[$k].item_id // empty' "$json_file" 2>/dev/null)

            if [[ -n "$task_url" ]]; then
                gh_try "close task $key" gh issue close "$task_url" >/dev/null 2>&1 || true
                [[ -n "$task_item_id" ]] && gh_update_status "$task_item_id" "done" || true
            fi
        done < <(_gh_parse_tasks < "$tasks_file")

        gh_update_epic_body "$repo_root" "$epic_num" "$tasks_file"
    fi
}

# Called after merge. Closes all task issues + epic issue, sets status to Done.
gh_sync_done() {
    $GH_ENABLED || return 0
    local repo_root="$1" epic_num="$2" tasks_file="${3:-}"

    local json_file
    json_file=$(_gh_task_json "$repo_root" "$epic_num")

    # Close all open task issues
    local task_keys
    task_keys=$(jq -r '.tasks | keys[]' "$json_file" 2>/dev/null)
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local url item_id
        url=$(jq -r --arg k "$key" '.tasks[$k].url // empty' "$json_file" 2>/dev/null)
        item_id=$(jq -r --arg k "$key" '.tasks[$k].item_id // empty' "$json_file" 2>/dev/null)
        [[ -n "$url" ]] && gh_try "close task $key" gh issue close "$url" >/dev/null 2>&1 || true
        [[ -n "$item_id" ]] && gh_update_status "$item_id" "done" || true
    done <<< "$task_keys"

    [[ -n "$tasks_file" ]] && [[ -f "$tasks_file" ]] && \
        gh_update_epic_body "$repo_root" "$epic_num" "$tasks_file"

    # Close and update epic issue
    local epic_url epic_item_id
    epic_url=$(jq -r '.epic.url // empty' "$json_file" 2>/dev/null)
    epic_item_id=$(jq -r '.epic.item_id // empty' "$json_file" 2>/dev/null)

    [[ -n "$epic_item_id" ]] && gh_update_status "$epic_item_id" "done" || true
    [[ -n "$epic_url" ]] && gh_try "close epic" gh issue close "$epic_url" >/dev/null 2>&1 || true

    log OK "GitHub: epic $epic_num synced as Done"
}

# ─── Resync ─────────────────────────────────────────────────────────────────

# Reconciliation-based resync: loop all epics, ensure issues exist, sync state.
# Non-destructive: never deletes issues, only creates missing ones and updates state.
gh_resync() {
    local repo_root="$1"
    local synced=0 tasks_synced=0

    log PHASE "GitHub resync: reconciling all epics"

    while IFS='|' read -r num status short_name title epic_file; do
        [[ -z "$num" ]] && continue

        local state
        state="$(detect_state "$repo_root" "$num" "$short_name")"

        gh_create_epic_issue "$repo_root" "$num" "$title"

        local tasks_file="$repo_root/specs/$short_name/tasks.md"
        if [[ -f "$tasks_file" ]]; then
            gh_create_task_issues "$repo_root" "$num" "$tasks_file"
            tasks_synced=$((tasks_synced + 1))
        fi

        gh_sync_phase "$repo_root" "$num" "$state" "$tasks_file"

        if [[ "$state" == "done" ]] || is_epic_merged "$repo_root" "$short_name" "$status" 2>/dev/null; then
            gh_sync_done "$repo_root" "$num" "$tasks_file"
        fi

        synced=$((synced + 1))
    done < <(list_epics "$repo_root" | sort -t'|' -k1,1)

    log OK "GitHub resync complete: $synced epics, $tasks_synced with tasks"
}
