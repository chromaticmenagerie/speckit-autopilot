# Implementation Plan: Epic Validation, Templates & Deferred Task Handling

> **Revision 7** — Fixes `install.sh` template copy to use `$TEMPLATE_DEST` variable following destination variable convention (2026-03-06).
> Changes from REV6 are marked with `[REV7]` annotations. Previous `[REV2]`–`[REV6]` annotations retained for traceability.

## Overview

Four changes to the speckit-autopilot orchestrator, ordered by priority:

1. **Epic template** — standardised markdown template for writing epics
2. **Pre-specify validation** — validate epic quality before spending tokens
3. **Deferred task handling** — `- [-]` marker for tasks that shouldn't block the pipeline
4. **Dependency status check** — verify referenced epics are merged before running

---

## 1. Epic Template

**New file**: `templates/TEMPLATE-epic.md`

A skeleton epic file with all required sections, placeholder text, and a self-containment checklist. This lives in the autopilot repo (not speckit) and gets copied into target projects via `install.sh`.

### `[REV2]` Template filename — glob collision fix

The `list_epics()` function in `autopilot-lib.sh:75` uses the glob `epic-*.md` to discover epics. A file named `epic-template.md` **matches this glob** and would be processed as a real epic (with `epic_id: epic-NNN`), potentially causing the autopilot to attempt to specify from placeholder text.

`[REV3]` **Confirmed safe**: `TEMPLATE-epic.md` does NOT match the `epic-*.md` glob. There is only one glob pattern in the entire codebase that matches epic files by name (`autopilot-lib.sh:75`), and all 48 file references across all source files were checked — no other pattern would accidentally match this filename.

**Fix**: Name the template `TEMPLATE-epic.md` instead of `epic-template.md`. This avoids the `epic-*.md` glob while remaining discoverable. The installed path becomes `docs/specs/epics/TEMPLATE-epic.md`.

### Template content

```markdown
---
document: epic
epic_id: epic-NNN
version: 1.0.0
status: draft
branch:
created: YYYY-MM-DD
project: PROJECT_NAME
---

# Epic: [Title]

**ID**: epic-NNN
**Description**: [1-2 sentence summary of what this epic delivers]

## Functional Requirements

### [Feature Area 1]

- The system shall ...
- When [condition], the system shall ...

### [Feature Area 2]

- The system shall ...

## Acceptance Criteria

### [Feature Area 1]

- [ ] [Testable assertion mapping to a functional requirement above]
- [ ] ...

### [Feature Area 2]

- [ ] ...

## Implementation Hints

1. [First step description] (depends on: [list dependencies])
2. [Second step] (depends on: 1)

## API Endpoints

| Method | Path | Description | Permissions |
|--------|------|-------------|-------------|
| GET    | `/api/v1/...` | ... | Authenticated |

## Out of Scope

- [Explicitly excluded item 1]
- [Explicitly excluded item 2]

## Dependencies

- **epic-NNN** ([Name]) — requires: [what specifically is needed from that epic]

## Self-Containment Checklist

- [ ] All functional requirements reference only tables/entities that exist or will be created in this epic
- [ ] No user story depends on tables or APIs from future (unmerged) epics
- [ ] Every acceptance criterion can be tested using only this epic's code + its merged dependencies
- [ ] The Dependencies section lists every referenced epic and its current status

## Notes

- [Context, historical references, library recommendations]

---

[<- Back to PRD](../prd.md)
```

### Install integration

**File**: `install.sh`

`[REV3]` `[REV7]` Add a step that copies `templates/TEMPLATE-epic.md` to `docs/specs/epics/TEMPLATE-epic.md`. Note: `install.sh` uses destination variables for all file copy/write operations (`$DEST`, `$SKILL_DEST`, `$VERSION_FILE`). The `$TARGET_REPO` variable does not exist in `install.sh`. A new `$TEMPLATE_DEST` variable follows this established convention.

```bash
# After Step 5 (skill file), before Step 6 (version marker):

# ── Step 5b: Install epic template ────────────────────────────────────────
TEMPLATE_DEST="docs/specs/epics"
mkdir -p "$TEMPLATE_DEST"
if [[ -f "$SRC_DIR/templates/TEMPLATE-epic.md" ]]; then
    cp "$SRC_DIR/templates/TEMPLATE-epic.md" "$TEMPLATE_DEST/TEMPLATE-epic.md"
    info "Epic template installed to $TEMPLATE_DEST/TEMPLATE-epic.md"
else
    warn "Epic template not found in source (skipped)"
fi
```

`[REV2]` `[REV7]` **Overwrite strategy**: Always overwrite on install/upgrade (matching the pattern used for scripts and skill files). The template is autopilot-owned content, not user-customized. This is consistent with how `install.sh` handles all other autopilot-authored files. The step uses `$TEMPLATE_DEST` variable with `mkdir -p` before copying, since this directory may not exist yet (install.sh currently only writes to `.specify/` and `.claude/`). The `$TEMPLATE_DEST` variable follows the same convention as `$DEST`, `$SKILL_DEST`, and `$VERSION_FILE`.

`[REV2]` **Version bump required**: Adding new files to the install flow requires bumping VERSION (e.g., `0.7.1` → `0.8.0`). Without this, existing installations hit the early `exit 0` on version equality check (line 97-101) and never receive the template.

`[REV3]` **`autopilot-validate.sh` must be added to the script copy loop**: The plan creates `src/autopilot-validate.sh` and sources it from `autopilot.sh`, but the `install.sh` script copy loop at line 116 must include it. Without this, installed autopilots would crash on `source: file not found`. Add `autopilot-validate.sh` to the `for script in ...` list at `install.sh:116`.

### Changes

| File | Change |
|------|--------|
| `templates/TEMPLATE-epic.md` | **New file** — the template above `[REV2]` renamed from `epic-template.md` |
| `install.sh` | Add template copy step (always overwrite, `$TEMPLATE_DEST` variable following `$DEST`/`$SKILL_DEST` convention) `[REV2]` `[REV3]` `[REV7]`; add `autopilot-validate.sh` to script copy loop at line 116 `[REV3]` |
| `VERSION` | Bump to `0.8.0` `[REV2]` |

---

## 2. Pre-Specify Validation (`autopilot-validate.sh`)

**New file**: `src/autopilot-validate.sh`

A validation script sourced by `autopilot.sh` that runs **before the first phase begins**. It performs structural validation of the epic markdown file and dependency status checks.

`[REV3]` **Grep safety**: Under `set -euo pipefail` (which propagates into sourced scripts running in the same shell process), every `grep` call must follow one of the 5 canonical safe patterns used throughout the codebase:

| Pattern | Example | Use case |
|---------|---------|----------|
| a. `if grep -q ... 2>/dev/null; then` | Boolean check | 20+ existing uses |
| b. `var=$(grep -c ... 2>/dev/null) \|\| var=0` | Counting | 8 existing uses |
| c. `var=$(grep -oE ... \|\| true)` | Extraction | 6 existing uses |
| d. `grep -q ... \|\| return 1` | Gate | 4 existing uses |
| e. `grep -q ... && action` | Conditional chain | 5 existing uses |

**Anti-pattern** (explicitly warned against at `autopilot-lib.sh:137-138`): never use `grep -q` in a pipeline with pipefail — grep -q exits early causing SIGPIPE.

For multi-line section extraction, the codebase uses `while IFS= read -r line` loops, NOT grep. The new `autopilot-validate.sh` MUST follow these patterns exactly.

### Validation checks

#### A. YAML Frontmatter Completeness

`[REV4]` **Reduced to only operationally-consumed fields.** An exhaustive trace across all 13 scripts confirmed that only `epic_id` and `status` are read by the orchestrator. `created` and `project` are never parsed by any function — they are documentation metadata only. Blocking on them would reject valid epics for no operational reason.

Parse the epic file's YAML frontmatter and verify fields:

**ERROR — blocks execution (fields the orchestrator depends on):**

| Field | Validation | Why it's required |
|-------|------------|-------------------|
| `epic_id` | Must match `epic-[0-9]{3}` pattern (standard 3-digit only) | Drives sort order, CLI targeting (`./autopilot.sh 003`), branch prefix validation, spec dir naming, design file lookup. A malformed ID (e.g., `epic-3` instead of `epic-003`) causes infinite specify loops and silent mismatches. |
| `status` | Must be one of: `draft`, `not-started`, `in-progress`, `merged` | Primary signal in `is_epic_merged()`. Without it, merged epics get re-processed, wasting tokens and potentially overwriting completed work. |

**WARN — non-blocking (metadata or self-healing fields):**

| Field | Validation | Why it's a warning |
|-------|------------|--------------------|
| `branch` | `[REV2]` Accept `# populated at sprint start` and empty values as valid "not yet assigned" state. 22 of 25 real epics use the placeholder. | Orchestrator self-heals: `detect_state()` returns `"specify"` for empty branch, and the branch is written back to YAML after the specify phase completes. |
| `created` | Should be a valid date (YYYY-MM-DD) if present | `[REV4]` Not parsed by any orchestrator function. Metadata for human reference only. |
| `project` | Should be non-empty if present | `[REV4]` Not parsed by any orchestrator function. Project name comes from `.specify/project.env`, not epic YAML. |

**IGNORED — no validation (not consumed by any code):**

| Field | Reason |
|-------|--------|
| `document` | Template boilerplate. Not parsed anywhere. |
| `version` | Schema version hint. Not parsed anywhere. |

#### B. Required Sections

Scan the epic markdown for required `##` headings:

| Section | Required | Severity |
|---------|----------|----------|
| `## Functional Requirements` | Yes | ERROR — blocks |
| `## Acceptance Criteria` | Yes | ERROR — blocks |
| `## Dependencies` | Yes | ERROR — blocks |
| `## Out of Scope` | No | WARN — non-blocking `[REV2]` downgraded from required |
| `## Self-Containment Checklist` | No | WARN — non-blocking |
| `## Implementation Hints` | No | WARN — non-blocking |

`[REV2]` Note: All 27 existing epics in the Brightwell_Practice repo contain all four originally-proposed required sections, so this validation would not break any existing epic. Out of Scope was downgraded as a safety measure since it's less critical than the other three.

#### C. Self-Containment Check

`[REV2]` **Rewritten to use `is_epic_merged()` instead of YAML-only status checks.**

Parse the `## Dependencies` section. For each referenced epic:

1. Find the corresponding epic file in `docs/specs/epics/`
2. Check merge status using `is_epic_merged()` (which checks YAML status **and** git merge history) — not YAML status alone. This is critical because all epics currently have `status: draft` in YAML even when already merged via git.
3. If NOT merged:
   - **Default mode**: WARN — "Epic-NNN depends on epic-XXX which is not yet merged"
   - **`--strict-deps` mode**: ERROR — blocks execution
4. `[REV2]` **Handle "None" dependencies**: `[REV3]` Use the tightened regex `^[[:space:]]*[Nn]one([[:space:]]|$)` to match "None" only as the first word on a line. The previous regex `[Nn]one` was too broad and would match substrings like "ComponentNone" or "none of these are hard blockers", incorrectly bypassing all dependency checks. If matched and no `epic-[0-9]{3}` references exist, treat as valid (no dependencies to check). This handles foundational epics like `epic-000`.
5. `[REV2]` **Handle partial dependencies**: If a "Partial dependency note" paragraph exists in the Dependencies section, downgrade all dependency errors to warnings even in `--strict-deps` mode, and log: "Partial dependency noted — dependency checks are advisory only".

**Dependency regex**: Use `epic-[0-9]{3}` to match standard 3-digit epic IDs. This is the same pattern used throughout the codebase.

#### D. Content Quality (Warnings only)

- Warn if `## Functional Requirements` section has fewer than 3 bullet points (count all `- ` lines between `## Functional Requirements` and the next `## ` heading, including under `###` subsections) `[REV5]`
- Warn if `## Acceptance Criteria` section has zero checkboxes (`- [ ]`)
- Warn if any acceptance criterion is not a checkbox
- Warn if `## Dependencies` references an epic that doesn't have a file

### Function signatures

```bash
# Main entry point — called from run_epic() before phase loop
# Returns 0 if valid, 1 if blocking errors found
validate_epic() {
    local repo_root="$1"
    local epic_num="$2"
    local epic_file="$3"
    # ...
}

# Individual check functions (internal)
_validate_frontmatter()    # YAML field checks
_validate_sections()       # Required ## headings
_validate_dependencies()   # Cross-epic merge status check [REV2]
_validate_content_quality() # Heuristic warnings
```

### Integration into `autopilot.sh`

**File**: `src/autopilot.sh`

1. Add `source "$SCRIPT_DIR/autopilot-validate.sh"` after the existing source lines (after line 31, which sources `autopilot-finalize.sh`)
2. `[REV2]` In `run_epic()`, add validation call **gated on pre-implement states only**:

```bash
# After prefix correction (line 476) and before state detection (line 481):

# ── Pre-flight epic validation ──
# [REV2] Only validate on early states — no point re-validating at implement/review
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
```

3. Add `--strict-deps` flag to argument parsing (in `parse_args()` at `autopilot.sh:107`):

```bash
--strict-deps) STRICT_DEPS=true ;;
```

With the global declaration (alongside the other globals at line 100-105):
```bash
STRICT_DEPS=false
```

### Changes

| File | Change |
|------|--------|
| `src/autopilot-validate.sh` | **New file** — ~200 lines, all validation logic `[REV2]` increased from 150 for partial-dep handling |
| `src/autopilot.sh` | Source the new script (after line 31); add `validate_epic` call gated on pre-implement states `[REV2]`; add `--strict-deps` flag; add `STRICT_DEPS=false` global |

---

## 3. Deferred Task Handling

Adds a new checkbox state `- [-]` meaning "deferred — don't count toward incomplete". This allows mixed-scope epics to complete without blocking on tasks that belong to a future epic.

### `[REV6]` Syntax choice: `- [-]` — rationale and rendering

`[REV6]` **Changed from `- [~]` to `- [-]`** based on repercussions analysis. `- [-]` is the most widely adopted non-standard checkbox marker:

| Factor | `- [-]` | `- [~]` |
|--------|---------|---------|
| Obsidian | "Cancelled" — Tasks plugin, Minimal theme, ITS theme | Not recognized |
| GitLab | Supported ("indeterminate") | Supported ("inapplicable") |
| GitHub | Plain text (neither renders as checkbox) | Plain text |
| Visual clarity | Bolder, centered horizontal stroke | Smaller, top-aligned tilde |
| Community | Most-requested 3rd state ([GitHub Discussion #19199](https://github.com/orgs/community/discussions/19199)) | Less grassroots adoption |
| Regex safety | `\[-\]` — `-` at end of bracket expression is literal per POSIX | `\[~\]` — no special meaning |

Both are safe in regex. `[-]` wins on ecosystem recognition, visual distinctiveness, and semantic fit ("cancelled/skipped" aligns with "deferred").

**Regex patterns** (verified on macOS Darwin 24.6.0 and confirmed POSIX-portable):
- `grep -c '^\- \[-\]'` — correctly counts deferred tasks, `^` anchor prevents mid-line false positives
- `[[ "$line" =~ ^-\ \[([\ x-])\]\ (.+) ]]` — `-` at end of bracket expression `[\ x-]` is literal (POSIX rule), correctly matches space, `x`, or `-`
- `sed 's/^\([[:space:]]*\)- \[ \]/\1- [-]/'` — preserves indentation, fully portable BSD/GNU
- Case-sensitive by design — enforces lowercase `[x]` convention. Uppercase `[X]` is not supported. All templates and prompts use lowercase exclusively, and case-sensitive matching aligns `detect_state()` with `_get_impl_progress()` (`autopilot-stream.sh:303-304`) and `_gh_parse_tasks()` (`autopilot-github-sync.sh:32`) which are already case-sensitive.

**Alternatives considered and rejected:**

| Syntax | Problem |
|--------|---------|
| `- [x] ~~deferred text~~` | `detect_state()` at `autopilot-lib.sh:257` counts ALL `- [x]` lines as complete (case-insensitive `-ci` flag). Deferred tasks would be counted as completed — semantically wrong. `_gh_parse_tasks()` would also match `[x]` and create GitHub issues marked "Done". |
| `- [ ] [DEFERRED] text` | Still counted as incomplete by `detect_state()`, `get_current_impl_phase()`, and `count_phase_incomplete()` — all match `^- \[ \]`. Would still block pipeline progression. The `[DEFERRED]` tag sits in the description portion that AI models edit freely, making it vulnerable to being stripped during implementation. |
| `- [~]` (REV5 choice) | `[REV6]` Rejected: less ecosystem recognition than `[-]`. Not recognized by Obsidian (the most popular markdown knowledge tool). `[-]` has broader grassroots adoption and is the most likely candidate if GitHub ever adds a third checkbox state. |

`- [-]` provides a clean third state: unambiguous to regex (`^\- \[-\]`), invisible to existing `[ ]` and `[x]` matchers, and structurally positioned in the checkbox slot where AI models treat it as syntax rather than editable content.

### Changes to `src/autopilot-lib.sh`

#### A. Update `detect_state()` (lines 254-280)

Current code counts `- [ ]` as incomplete and `- [x]` as complete. Change to:

```bash
# Count task states (lines 254-279)
local incomplete complete deferred
incomplete=$(grep -c '^\- \[ \]' "$spec_dir/tasks.md" 2>/dev/null) || incomplete=0
complete=$(grep -c '^\- \[x\]' "$spec_dir/tasks.md" 2>/dev/null) || complete=0
deferred=$(grep -c '^\- \[-\]' "$spec_dir/tasks.md" 2>/dev/null) || deferred=0

if [[ "$incomplete" -gt 0 ]]; then
    echo "implement"
    return
fi

# [REV2] CRITICAL FIX: Include deferred in the "has work been done" check.
# Without this, all-deferred-zero-complete falls through to the edge case
# at line 278 and returns "tasks" instead of progressing to review.
if [[ "$((complete + deferred))" -gt 0 ]]; then
    # All tasks done or deferred — check if already merged
    if is_epic_merged "$repo_root" "$short_name"; then
        echo "done"
    elif ! grep -q '<!-- SECURITY_REVIEWED -->' "$spec_dir/tasks.md" 2>/dev/null; then
        echo "security-review"
    else
        echo "review"
    fi
    return
fi
```

Key behavior: `- [-]` tasks are **not** counted as incomplete, so they don't block progression to security-review/review/merge. They **are** reported in the progress display.

`[REV2]` **Edge case fix**: The original plan had a bug where all-deferred-zero-complete would fall through to line 278 and return `"tasks"`, creating an infinite loop. The condition `if [[ "$complete" -gt 0 ]]` is now `if [[ "$((complete + deferred))" -gt 0 ]]`.

**Note on downstream consumers**: 4 callers of `detect_state()` all consume string return values — no changes needed. 3 checkbox-parsing functions (`get_current_impl_phase`, `count_phase_incomplete`, `count_phases`) all correctly ignore `[-]` already since they only match `^- \[ \]` — NO changes needed.

#### B. Update progress display in `autopilot-stream.sh`

In `_get_impl_progress()` (lines 300-308), add a third grep for deferred tasks:

```bash
local cur total inc comp def
cur=$(get_current_impl_phase "$tasks_file")
total=$(count_phases "$tasks_file")
inc=$(grep -c '^\- \[ \]' "$tasks_file" 2>/dev/null) || inc=0
comp=$(grep -c '^\- \[x\]' "$tasks_file" 2>/dev/null) || comp=0
def=$(grep -c '^\- \[-\]' "$tasks_file" 2>/dev/null) || def=0
_impl_progress_cache=$(jq -nc \
    --argjson cp "${cur:-0}" --argjson tp "${total:-0}" \
    --argjson ic "${inc:-0}" --argjson cc "${comp:-0}" \
    --argjson dc "${def:-0}" \
    '{current_phase:$cp, total_phases:$tp, tasks_complete:$cc, tasks_remaining:$ic, tasks_deferred:$dc}')
```

Update the dashboard header in `_print_dashboard_header()` (`autopilot-stream.sh:361-386`):

```bash
# Show task progress for implement phase (lines 370-382)
if [[ "$phase" == "implement" ]]; then
    local prog
    prog=$(_get_impl_progress "$epic")
    local comp rem cur tot def
    comp=$(echo "$prog" | jq '.tasks_complete // 0')
    rem=$(echo "$prog" | jq '.tasks_remaining // 0')
    cur=$(echo "$prog" | jq '.current_phase // 0')
    tot=$(echo "$prog" | jq '.total_phases // 0')
    def=$(echo "$prog" | jq '.tasks_deferred // 0')
    if [[ "$tot" -gt 0 ]]; then
        if [[ "$def" -gt 0 ]]; then
            printf "  ${BOLD}║${RESET}  Tasks: ${GREEN}%d done${RESET} / ${YELLOW}%d remaining${RESET} / ${DIM}%d deferred${RESET} (phase %s/%s)\n" \
                "$comp" "$rem" "$def" "$cur" "$tot"
        else
            printf "  ${BOLD}║${RESET}  Tasks: ${GREEN}%d done${RESET} / ${YELLOW}%d remaining${RESET} (phase %s/%s)\n" \
                "$comp" "$rem" "$cur" "$tot"
        fi
    fi
fi
```

Update the watch dashboard in `autopilot-watch.sh`:

In `read_status()` (lines 116-134), add `tasks_deferred` to the jq extraction and IFS read:

```bash
parsed=$(jq -r '[
    .epic // "", .phase // "", (.cost_usd // 0 | tostring),
    (.tokens.input // 0 | tostring), (.tokens.output // 0 | tostring),
    .last_tool // "", (.pid // "" | tostring), .last_activity_at // "",
    (.implement_progress.current_phase // "" | tostring),
    (.implement_progress.total_phases // "" | tostring),
    (.implement_progress.tasks_complete // "" | tostring),
    (.implement_progress.tasks_remaining // "" | tostring),
    (.implement_progress.tasks_deferred // "" | tostring)
] | join("\t")' "$STATUS_FILE" 2>/dev/null) || return 1
[[ -z "$parsed" ]] && return 1
IFS=$'\t' read -r STATUS_EPIC STATUS_PHASE STATUS_COST STATUS_TOKENS_IN \
    STATUS_TOKENS_OUT STATUS_LAST_TOOL STATUS_PID STATUS_LAST_ACTIVITY \
    IMPL_CURRENT_PHASE IMPL_TOTAL_PHASES IMPL_TASKS_COMPLETE \
    IMPL_TASKS_REMAINING IMPL_TASKS_DEFERRED <<< "$parsed"
```

In `render_impl_progress()` (lines 332-360), show deferred count:

```bash
render_impl_progress() {
    [[ "$STATUS_PHASE" != "implement" ]] && return
    [[ -z "$IMPL_TOTAL_PHASES" || "$IMPL_TOTAL_PHASES" == "null" ]] && return

    local sep
    sep=$(printf '─%.0s' $(seq 1 $(( TERM_COLS - 4 )) ))
    printf "\n  ${DIM}── Implement Progress %s${RESET}\n" "${sep:22}"

    local done_n="${IMPL_TASKS_COMPLETE:-0}"
    local rem_n="${IMPL_TASKS_REMAINING:-0}"
    local def_n="${IMPL_TASKS_DEFERRED:-0}"
    local total=$(( done_n + rem_n + def_n ))
    local pct=0
    [[ $total -gt 0 ]] && pct=$(( (done_n + def_n) * 100 / total ))

    if [[ "$def_n" -gt 0 ]]; then
        printf "  Phase %s/%s · %s done / %s remaining / %s deferred\n" \
            "${IMPL_CURRENT_PHASE:-?}" "${IMPL_TOTAL_PHASES:-?}" "$done_n" "$rem_n" "$def_n"
    else
        printf "  Phase %s/%s · %s done / %s remaining\n" \
            "${IMPL_CURRENT_PHASE:-?}" "${IMPL_TOTAL_PHASES:-?}" "$done_n" "$rem_n"
    fi

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
```

#### `[REV6]` C. `_gh_parse_tasks()` in `autopilot-github-sync.sh` — Skip deferred, render in epic body

`[REV6]` **Revised from REV2 "keep invisible" approach.** Deferred tasks are now parsed but skipped for issue creation, and rendered with strikethrough in the epic body. This provides visibility without the complexity of labels or board status changes.

The regex at `autopilot-github-sync.sh:32` is expanded to recognize `[-]`:
```bash
# [REV6] Was: ([\ x])  Now includes - for deferred
[[ "$line" =~ ^-\ \[([\ x-])\]\ (.+) ]]
```

**Note on `[-]` in the regex**: The `-` at the end of the bracket expression `[\ x-]` is literal per POSIX — it does NOT create a range. Verified on macOS (BSD) and Linux (GNU).

**Changes (3 touch points, ~8 lines):**

1. **`_gh_parse_tasks()` line 32**: Expand regex to `([\ x-])` so deferred tasks appear in parse output with `checked == "-"`

2. **`gh_create_task_issues()`** (~line 105): Skip deferred tasks — don't create GitHub issues:
```bash
while IFS='|' read -r key checked desc; do
    [[ -z "$key" ]] && continue
    [[ "$checked" == "-" ]] && continue   # [REV6] skip deferred, don't create issue
    # ... existing issue creation logic
```

3. **`gh_update_epic_body()`** (~line 197): Render deferred tasks without checkbox (prevents accidental GFM toggle):
```bash
if [[ "$checked" == "-" ]]; then
    # [REV6] No checkbox — strikethrough prevents accidental GitHub toggle
    body+="- ~~[${epic_num}-${key}] ${desc}~~ *(deferred)*"$'\n'
elif [[ "$checked" == "x" ]]; then
    checkbox="[x]"
    done_count=$((done_count + 1))
    body+="- ${checkbox} [${epic_num}-${key}] ${desc} (#${issue_num})"$'\n'
else
    body+="- [ ] [${epic_num}-${key}] ${desc} (#${issue_num})"$'\n'
fi
```

**Why NOT `- [ ] ~~desc~~`**: GitHub renders `- [ ]` as an interactive checkbox. Users clicking it would modify the issue body directly on GitHub, desynchronizing it from local `tasks.md`. Using no checkbox prefix avoids this entirely.

**No changes needed to:**
- `gh_sync_phase()` — existing `[[ "$checked" != "x" ]] && continue` already skips non-complete tasks (including `-`)
- `gh_sync_done()` — already closes all issues from JSON cache at merge time regardless of checkbox state
- No new labels, no board status changes, zero additional API calls

#### `[REV6]` D. Update `prompt_implement()` in `autopilot-prompts.sh`

`[REV6]` **Two changes** to ensure Claude skips deferred tasks:

**1. Add a static paragraph** in the prompt body (after line 372, the `Also read CLAUDE.md...` line, before line 374, the `When launching Task subagents...` block):

```
IMPORTANT: Tasks marked - [-] in tasks.md are DEFERRED. Skip them entirely —
do not implement them, do not mark them [x], do not create subagents for them.
Only process tasks marked - [ ] (incomplete).
```

This is placed BEFORE the subagent instruction block so Claude understands deferred semantics before dispatching any work.

**2. Update the `args` value** (line 385) to reinforce the instruction at skill invocation:

```
args = "all tasks using subagents for parallel [P] tasks — IMPORTANT: tasks marked - [-] are deferred and MUST be skipped entirely, do not attempt to implement them"
```

Both are prompt-based mitigations since we cannot modify the external speckit skill. The instruction flows through Claude to the skill invocation. The `args` value is literal text that Claude reads and passes to the Skill tool — it is not parsed by the shell.

### `[REV2]` Implement force-advance — redesigned

The original plan auto-deferred ALL remaining `- [ ]` tasks across ALL phases after max retries. This was identified as having critical risks:

1. **Indiscriminate deferral**: A single stuck task in Phase 4 would defer untouched tasks in Phases 5-7
2. **Security review gap**: Security-review prompt doesn't check for deferred tasks
3. **Review assumes 100% completion**: Review prompt opens with "All implementation tasks are complete"
4. **No post-merge tracking**: Deferred tasks buried with no follow-up mechanism
5. **Pattern break**: All 6 existing force-advance cases append markers; this modifies content

#### `[REV2]` New design: `--allow-deferred` flag + scoped deferral

**Behavior without `--allow-deferred`** (default): Implement phase hits max retries → pipeline stops with error (current behavior preserved). Log message suggests: `"Hint: re-run with --allow-deferred to defer stuck tasks and continue"`.

**Behavior with `--allow-deferred`**: Implement phase hits max retries → defer only tasks in the **stuck phase** (not all phases):

`[REV3]` **Corrected pseudocode** — fixes C1 (invalid bash syntax), C2 (missing phase boundary reset), and M2 (empty `stuck_phase` guard):

```bash
elif [[ "$state" == "implement" ]] && [[ -f "$spec_dir/tasks.md" ]]; then
    if ! ${ALLOW_DEFERRED:-false}; then
        log ERROR "Implement stuck after $retries attempts. Re-run with --allow-deferred to defer stuck tasks."
        log ERROR "Resume with: ./autopilot.sh $epic_num --allow-deferred"
        return 1
    fi

    # Scope deferral to the stuck phase only
    local stuck_phase
    stuck_phase=$(get_current_impl_phase "$spec_dir/tasks.md")

    # [REV3] M2 fix: guard against empty stuck_phase
    if [[ -z "$stuck_phase" ]]; then
        log ERROR "Cannot determine stuck phase — no incomplete tasks found. This should not happen."
        return 1
    fi

    log WARN "Implement: deferring incomplete tasks in Phase $stuck_phase only"

    # Convert - [ ] to - [-] ONLY within the stuck phase section
    # [REV3] C1+C2 fix: correct bash syntax and proper phase boundary reset
    # Pattern matches count_phase_incomplete() at autopilot-lib.sh:321-338
    local in_phase=false phase_num=""
    local tmpfile="$spec_dir/tasks.md.tmp"
    : > "$tmpfile"  # truncate before writing (prevents stale content from failed runs)
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

    # Append audit marker listing which tasks were auto-deferred
    # [REV6] Use printf instead of echo -e for POSIX portability
    # (macOS /bin/echo does not support -e; bash built-in does, but printf is safer)
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
```

**Key differences from v1**:
- **Opt-in via `--allow-deferred`** — pipeline stops by default (safe)
- **Scoped to the stuck phase** — uses existing `get_current_impl_phase()` helper instead of global `sed`
- **Audit marker** — `<!-- FORCE_DEFERRED: Phase N (M tasks) -->` distinguishes auto-deferral from manual
- **Future phases remain `- [ ]`** — they'll be attempted on the next `implement` retry cycle
- `[REV3]` **Empty `stuck_phase` guard** — prevents silent data corruption if `get_current_impl_phase()` returns empty
- `[REV3]` **Cascading deferral circuit breaker** — stops after 2 consecutive phases deferred to avoid burning tokens on cascading failures

The `consecutive_deferred` counter must be initialized before the phase loop in `run_epic()`:

```bash
# Before the phase loop (after line 488):
local consecutive_deferred=0
```

And reset to 0 when an implement phase succeeds (add inside the state-advanced check at line 620):

```bash
if [[ "$new_state" != "$prev_state" ]]; then
    consecutive_deferred=0  # Reset on successful phase transition
    log OK "Phase $prev_state → $new_state (exit=$phase_exit)"
    # ...
fi
```

#### `[REV6]` E. Update security-review and review prompts

**`prompt_security_review()`** (`autopilot-prompts.sh:412`): Add instruction:
```
Before reviewing, check tasks.md for any deferred tasks (- [-]). If deferred tasks exist,
note which functionality is NOT implemented and flag any security implications of the missing
code (e.g., missing authorization checks, missing input validation for deferred endpoints).
```

`[REV6]` **Also add conditional deferred-awareness injection** at the `prompt_security_review()` call site in `run_phase()`, following the same pattern as review:

```bash
# In run_phase(), inside the security-review case (after generating the base prompt):
security-review)
    prompt="$(prompt_security_review "$epic_num" "$title" "$repo_root" "$short_name")"
    # [REV6] Conditional deferred-awareness injection (same pattern as review)
    local _sec_deferred_count
    _sec_deferred_count=$(grep -c '^\- \[-\]' "$spec_dir/tasks.md" 2>/dev/null) || _sec_deferred_count=0
    if [[ "$_sec_deferred_count" -gt 0 ]]; then
        prompt+=$'\n\n'"IMPORTANT: ${_sec_deferred_count} tasks in tasks.md are marked - [-] (deferred). These were NOT implemented. Check whether the omitted functionality creates security gaps (missing auth checks, missing input validation, missing rate limiting for deferred endpoints)."
    fi
    ;;
```

**`prompt_review()`** (`autopilot-prompts.sh:452`): `[REV3]` **Use conditional prompt injection instead of weakening the base prompt.** The base prompt stays unchanged: "All implementation tasks are complete. Perform a senior code review." This preserves the strong review assertion for the normal case (zero deferred tasks), avoiding regression where the model wastes time checking for deferred tasks that don't exist.

The conditional injection happens at the orchestrator level in `run_phase()` (`autopilot.sh:203`), not in `prompt_review()`:

```bash
# In run_phase(), inside the review case (after generating the base prompt):
review)
    prompt="$(prompt_review "$epic_num" "$title" "$repo_root" "$short_name")"
    # [REV3] Conditional deferred-awareness injection
    local _review_deferred_count
    _review_deferred_count=$(grep -c '^\- \[-\]' "$spec_dir/tasks.md" 2>/dev/null) || _review_deferred_count=0
    if [[ "$_review_deferred_count" -gt 0 ]]; then
        prompt+=$'\n\n'"IMPORTANT: ${_review_deferred_count} tasks in tasks.md are marked - [-] (deferred). These were NOT implemented. Verify deferred tasks don't leave security holes, broken imports, or dead code paths. Note deferred scope in your review summary."
    fi
    ;;
```

#### `[REV2]` F. Post-merge deferred task tracking

Add to `write_epic_summary()` in `autopilot-lib.sh` (after line 406):
```bash
# Count deferred tasks and include in summary
local deferred_count
deferred_count=$(grep -c '^\- \[-\]' "$repo_root/specs/$short_name/tasks.md" 2>/dev/null) || deferred_count=0
if [[ "$deferred_count" -gt 0 ]]; then
    # List deferred task descriptions
    local deferred_list
    deferred_list=$(grep '^\- \[-\]' "$repo_root/specs/$short_name/tasks.md" | sed 's/^- \[-\] /- /' || true)
fi
```

Include in the summary markdown:
```markdown
## Deferred Tasks ($deferred_count)

$deferred_list

> These tasks were deferred during implementation and may need follow-up.
```

#### `[REV5]` G. Cross-epic deferred task accumulation check

Add to `run_finalize()` in `autopilot-finalize.sh`, before Step 3 (project summary). `run_finalize()` runs **once for the whole project** (called from `main()` at `autopilot.sh:784` only when all epics are merged), so this scan is not per-epic overhead.

```bash
# ── Step 2b: Deferred task accumulation check ──
local total_deferred=0
local count
for tasks_file in "$repo_root"/specs/*/tasks.md; do
    [[ ! -f "$tasks_file" ]] && continue
    count=$(grep -c '^\- \[-\]' "$tasks_file" 2>/dev/null) || count=0
    total_deferred=$((total_deferred + count))
done

if [[ "$total_deferred" -gt 0 ]]; then
    log WARN "Project has $total_deferred deferred tasks across all epics — consider creating a follow-up epic"
fi
```

This new glob `$repo_root/specs/*/tasks.md` covers the same file locations targeted individually by the 4 existing `$short_name`-based references (`autopilot.sh:358,503,625`, `autopilot-github-sync.sh:309`). The grep pattern follows canonical pattern (b) — safe under `set -euo pipefail`.

**Note**: This emits a `log WARN` only. The deferred total is NOT added to `write_project_summary()` output — per-epic deferred task listing in `write_epic_summary()` (Section 3F) provides sufficient detail. The project-level warning serves as an aggregated alert, not a detailed report.

#### H. Manual deferral support

Users can manually mark tasks as `- [-]` before or during a run. The orchestrator will simply skip them — no special handling needed beyond the counting change in `detect_state()`.

### Changes

| File | Change |
|------|--------|
| `src/autopilot-lib.sh` | Update `detect_state()` to count `- [-]` separately; fix all-deferred edge case `[REV2]` |
| `src/autopilot.sh` | Add implement force-advance with `--allow-deferred` gate and scoped deferral `[REV2]`; add `ALLOW_DEFERRED=false` global and CLI flag; add `consecutive_deferred` counter `[REV3]`; add conditional deferred-awareness injection for review and security-review prompts `[REV3]` `[REV6]` |
| `src/autopilot-stream.sh` | Include `tasks_deferred` in status JSON and dashboard header |
| `src/autopilot-watch.sh` | Show deferred count in dashboard progress line and `read_status()` jq extraction |
| `src/autopilot-prompts.sh` | Update implement prompt with static deferred-skip paragraph `[REV6]` and security-review prompt for deferred awareness `[REV2]`; review prompt left unchanged — conditional injection in autopilot.sh instead `[REV3]` |
| `src/autopilot-lib.sh` | Update `write_epic_summary()` to list deferred tasks `[REV2]` |
| `src/autopilot-finalize.sh` | Add deferred task accumulation warning in `run_finalize()` `[REV5]` |
| `src/autopilot-github-sync.sh` | Expand `_gh_parse_tasks()` regex to `([\ x-])`, skip deferred in `gh_create_task_issues()`, render strikethrough in `gh_update_epic_body()` `[REV6]` |

---

## 4. Pre-Specify Dependency Status Check

This is **part of the validation script** (item 2 above) but deserves explicit specification for the dependency-walk logic.

### Dependency parsing algorithm

`[REV2]` **Key changes from v1**:
- Uses `is_epic_merged()` (YAML + git history) instead of YAML status alone
- Handles "None" dependencies gracefully
- Respects "Partial dependency note" paragraphs

`[REV3]` **Key changes from REV2**:
- Dependency regex is `epic-[0-9]{3}` (standard 3-digit only, no letter suffix)
- "None" regex tightened to `^[[:space:]]*[Nn]one([[:space:]]|$)` to prevent substring false positives

```bash
_validate_dependencies() {
    local repo_root="$1"
    local epic_file="$2"
    local epic_num="$3"

    local in_deps=false
    local errors=0
    local warnings=0
    local has_partial_note=false

    while IFS= read -r line; do
        # Enter dependencies section
        if [[ "$line" =~ ^##[[:space:]]+Dependencies ]]; then
            in_deps=true
            continue
        fi
        # Exit on next ## heading
        if $in_deps && [[ "$line" =~ ^## ]]; then
            break
        fi

        if $in_deps; then
            # [REV3] Detect "None" dependencies (foundational epics)
            # Tightened regex: match "None" only as the first word on a line
            # Prevents false positives on "ComponentNone" or "none of these are hard blockers"
            if [[ "$line" =~ ^[[:space:]]*[Nn]one([[:space:]]|$) ]]; then
                return 0  # No dependencies to check
            fi

            # [REV2] Detect partial dependency notes
            if [[ "$line" =~ [Pp]artial[[:space:]]dependency[[:space:]]note ]]; then
                has_partial_note=true
            fi

            # Extract epic references (standard 3-digit IDs only)
            local refs
            refs=$(echo "$line" | grep -oE 'epic-[0-9]{3}' || true)
            for ref in $refs; do
                local ref_num="${ref#epic-}"
                # Skip self-reference
                [[ "$ref_num" == "$epic_num" ]] && continue

                # Find the referenced epic file (try exact match first, then glob)
                local ref_file=""
                if [[ -f "$repo_root/docs/specs/epics/${ref}.md" ]]; then
                    ref_file="$repo_root/docs/specs/epics/${ref}.md"
                else
                    # Try glob for files like epic-010-dashboard-feature.md
                    for f in "$repo_root/docs/specs/epics/${ref}"-*.md; do
                        [[ -f "$f" ]] && ref_file="$f" && break
                    done
                fi

                if [[ -z "$ref_file" ]]; then
                    log WARN "Dependency $ref: epic file not found"
                    warnings=$((warnings + 1))
                    continue
                fi

                # [REV2] Use is_epic_merged() — checks YAML status AND git history
                local ref_short_name=""
                # Parse branch from referenced epic's YAML
                local in_fm=false
                while IFS= read -r fmline; do
                    if [[ "$fmline" == "---" ]]; then
                        if $in_fm; then break; fi
                        in_fm=true; continue
                    fi
                    if $in_fm && [[ "$fmline" =~ ^branch:\ *(.+) ]]; then
                        ref_short_name="${BASH_REMATCH[1]}"
                        # Skip YAML comments used as placeholders
                        [[ "$ref_short_name" =~ ^# ]] && ref_short_name=""
                    fi
                done < "$ref_file"

                local ref_yaml_status=""
                in_fm=false
                while IFS= read -r fmline; do
                    if [[ "$fmline" == "---" ]]; then
                        if $in_fm; then break; fi
                        in_fm=true; continue
                    fi
                    if $in_fm && [[ "$fmline" =~ ^status:\ *(.+) ]]; then
                        ref_yaml_status="${BASH_REMATCH[1]}"
                    fi
                done < "$ref_file"

                if ! is_epic_merged "$repo_root" "$ref_short_name" "$ref_yaml_status"; then
                    local msg="Epic $epic_num depends on $ref which is not yet merged"
                    # [REV2] Partial dependency note downgrades errors to warnings
                    if $STRICT_DEPS && ! $has_partial_note; then
                        log ERROR "$msg"
                        errors=$((errors + 1))
                    else
                        log WARN "$msg"
                        warnings=$((warnings + 1))
                    fi
                else
                    # [REV6] Check merged dependency for deferred tasks
                    if [[ -n "$ref_short_name" ]]; then
                        local dep_tasks="$repo_root/specs/$ref_short_name/tasks.md"
                        if [[ -f "$dep_tasks" ]]; then
                            local dep_deferred
                            dep_deferred=$(grep -c '^\- \[-\]' "$dep_tasks" 2>/dev/null) || dep_deferred=0
                            if [[ "$dep_deferred" -gt 0 ]]; then
                                log WARN "Dependency $ref ($ref_short_name) is merged but has $dep_deferred deferred task(s):"
                                grep '^\- \[-\]' "$dep_tasks" 2>/dev/null | head -3 | while IFS= read -r dtask; do
                                    log WARN "  $dtask"
                                done
                                if [[ "$dep_deferred" -gt 3 ]]; then
                                    log WARN "  ... and $((dep_deferred - 3)) more"
                                fi
                                log WARN "Review these to check if epic-$epic_num depends on any."
                                warnings=$((warnings + 1))
                            fi
                        fi
                    fi
                fi
            done
        fi
    done < "$epic_file"

    if $has_partial_note && [[ $warnings -gt 0 ]]; then
        log INFO "Partial dependency note found — dependency warnings are advisory only"
    fi

    [[ $errors -gt 0 ]] && return 1
    return 0
}
```

### Circular dependency detection

Additionally, scan for circular references. Build a simple adjacency list from all epic files, then check for cycles using DFS:

```bash
_check_circular_deps() {
    local repo_root="$1"
    # Build adjacency: epic-NNN -> [epic-MMM, ...]
    # DFS with visited/in-stack tracking
    # Warn on any cycle found
}
# [DEFERRED] — Cycle detection deferred to a future revision. Warning-only, non-blocking.
```

This is a **warning only** — it doesn't block execution but alerts the developer to fix their dependency graph. `[DEFERRED]` — Implementation deferred; the stub above is pseudocode only. Per-epic dependency validation (`_validate_dependencies()`) still catches missing/unmerged deps. Circular structures are benign from a file-validation perspective — they would only cause operational confusion when waiting for unresolvable merge chains.

### `[REV6]` Cross-epic deferred task awareness

When a dependency IS merged, the validator additionally checks its `tasks.md` for deferred tasks (`- [-]`). This catches the case where a dependency was accepted as "done" but had tasks punted that downstream epics might depend on.

**Data flow**: `epic file → YAML branch field → specs/<branch>/tasks.md → grep for - [-]`

**Edge cases handled:**
- Pre-`[-]` epics: grep returns 0, no warning emitted
- Missing `tasks.md`: file existence guard skips silently
- Placeholder branch (`# populated at sprint start`): `ref_short_name` is empty, condition skips
- Output capped at first 3 tasks with total count to avoid log flooding

**Severity**: WARN only (non-blocking). The developer decides if any deferred tasks affect their epic.

### Changes

| File | Change |
|------|--------|
| `src/autopilot-validate.sh` | `_validate_dependencies()` function (included in the ~200 lines from item 2); `_check_circular_deps()` `[DEFERRED]` |

---

## File Change Summary

| File | Status | Est. Lines | Description |
|------|--------|-----------|-------------|
| `templates/TEMPLATE-epic.md` | **New** | ~80 | Standardised epic skeleton `[REV2]` renamed |
| `src/autopilot-validate.sh` | **New** | ~200 | Full validation with `is_epic_merged()` dependency checks, partial-dep handling, tightened "None" regex, cross-epic deferred awareness `[REV2]` `[REV3]` `[REV6]`; `_check_circular_deps()` `[DEFERRED]` |
| `src/autopilot.sh` | **Modified** | +45 | Source validate script, gated validation `[REV2]`, `--strict-deps`, `--allow-deferred` `[REV2]`, scoped force-advance with corrected bash syntax `[REV3]`, cascading deferral circuit breaker `[REV3]`, conditional review + security-review deferred injection `[REV3]` `[REV6]` |
| `src/autopilot-lib.sh` | **Modified** | +15 | `detect_state()` with deferred count + edge case fix `[REV2]`, `write_epic_summary()` deferred listing `[REV2]` |
| `src/autopilot-stream.sh` | **Modified** | +10 | Add `tasks_deferred` to status JSON and dashboard header |
| `src/autopilot-watch.sh` | **Modified** | +15 | Show deferred count in dashboard progress line, add to `read_status()` jq extraction |
| `src/autopilot-prompts.sh` | **Modified** | +15 | Deferred-aware implement prompt with static skip paragraph `[REV6]` and security-review prompt `[REV2]`; review prompt unchanged `[REV3]` |
| `install.sh` | **Modified** | +12 | Copy template (always overwrite, `mkdir -p "docs/specs/epics"`), add `autopilot-validate.sh` to script copy loop `[REV2]` `[REV3]` |
| `VERSION` | **Modified** | 1 | Bump to `0.8.0` `[REV2]` |
| `src/autopilot-finalize.sh` | **Modified** | +12 | Deferred task accumulation warning in `run_finalize()` `[REV5]` |
| `src/autopilot-github-sync.sh` | **Modified** | +10 | Expand `_gh_parse_tasks()` regex to `([\ x-])`, skip deferred in issue creation, strikethrough rendering in epic body `[REV6]` |
| `README.md` | **Modified** | +25 | Document new flags, template, deferred tasks, GitHub sync limitation |

**Total new code**: ~475 lines across 2 new files and 11 modified files. `[REV6]` increased from ~445 due to GH sync changes, prompt additions, and cross-epic deferred awareness.

---

## Implementation Order

### Step 1: Create epic template
- Create `templates/TEMPLATE-epic.md` `[REV2]` renamed
- Update `install.sh` to copy it (always overwrite, `$TEMPLATE_DEST` variable following destination variable convention) `[REV2]` `[REV3]` `[REV7]`
- Bump `VERSION` to `0.8.0` `[REV2]`

### Step 2: Create validation script
- Create `src/autopilot-validate.sh` with all validation functions
- Use `epic-[0-9]{3}` regex for epic IDs (standard 3-digit only)
- Use `is_epic_merged()` for dependency checks `[REV2]`
- Use tightened "None" regex: `^[[:space:]]*[Nn]one([[:space:]]|$)` `[REV3]`
- Handle "None" dependencies and partial dependency notes `[REV2]`
- Follow the 5 canonical grep-safe patterns exactly `[REV3]`
- Wire into `autopilot.sh` (source after line 31 + call in `run_epic()`, gated on pre-implement states) `[REV2]`
- Add `--strict-deps` flag to argument parsing
- Add `STRICT_DEPS=false` global
- Add `autopilot-validate.sh` to `install.sh` script copy loop at line 116 `[REV3]`

### Step 3: Add deferred task handling
- Update `detect_state()` in `autopilot-lib.sh` with `complete + deferred` edge case fix `[REV2]`
- Add `--allow-deferred` flag and `ALLOW_DEFERRED=false` global `[REV2]`
- Add implement force-advance case scoped to stuck phase only `[REV2]`, with corrected bash syntax `[REV3]`
- Add empty `stuck_phase` guard `[REV3]`
- Add `consecutive_deferred` counter and circuit breaker (stop at 2) `[REV3]`
- Add `<!-- FORCE_DEFERRED: Phase N -->` audit marker `[REV2]`
- Expand `_gh_parse_tasks()` regex to `([\ x-])`, skip deferred in `gh_create_task_issues()`, render strikethrough in `gh_update_epic_body()` `[REV6]`
- Add static deferred-skip paragraph to `prompt_implement()` body `[REV6]`
- Update implement args and security-review prompt in `autopilot-prompts.sh` `[REV2]` `[REV6]`
- Add conditional deferred injection for review AND security-review prompts in `autopilot.sh` (NOT in prompt functions) `[REV3]` `[REV6]`
- Update `write_epic_summary()` to list deferred tasks `[REV2]`
- Update status JSON and dashboard header in `autopilot-stream.sh`
- Update `read_status()` and `render_impl_progress()` in `autopilot-watch.sh`
- Add deferred task accumulation check in `run_finalize()` of `autopilot-finalize.sh` `[REV5]`

### Step 4: Update documentation
- Update `README.md` with new features, flags, and deferred task semantics
- Document GitHub sync known limitation for deferred tasks `[REV2]`
- Update `--help` output in `parse_args()` for `--strict-deps` and `--allow-deferred`

### Step 5: Add tests
- Add `tests/test-validate.sh` — test each validation check with mock epic files
  - Valid/invalid frontmatter, `branch: #` placeholders `[REV2]`
  - Required/missing sections
  - Dependency checks with mock merged/unmerged epics
  - "None" dependencies and partial dependency notes `[REV2]`
  - "None" regex: verify it does NOT match "ComponentNone" or "none of these" `[REV3]`
  - Empty/missing epic files
- Add `tests/test-deferred.sh` — test `detect_state()` with `- [-]` markers
  - Mix of `[x]`, `[-]`, `[ ]` → returns "implement"
  - All `[x]` + some `[-]` → returns "security-review"/"review"
  - All `[-]` zero `[x]` → returns "security-review" (not "tasks") `[REV2]` edge case
  - Scoped deferral only affects stuck phase (verify in_phase reset) `[REV2]` `[REV3]`
  - Empty `stuck_phase` guard triggers error `[REV3]`
  - Cascading deferral stops after 2 consecutive phases `[REV3]`
- Update `tests/test-install.sh` — assert template copied to `docs/specs/epics/TEMPLATE-epic.md` `[REV2]`; assert `autopilot-validate.sh` in script copy list `[REV3]`

---

## `[REV2]` Risks Accepted

These were identified during repercussions analysis and accepted as managed risks:

1. **Speckit skill interaction with `- [-]`**: The `/speckit.implement` skill is external. We mitigate via prompt instructions (static paragraph + args instruction `[REV6]`) but cannot guarantee the skill handles `[-]` correctly. If it doesn't, it will simply try to implement deferred tasks (which is no worse than the current behavior of retrying everything).

2. **Prompt-based mitigation fragility**: Instructions to skip `[-]` tasks flow through Claude to the skill. This is inherently fragile but is the only option without modifying the external speckit dependency. `[REV6]` Mitigated with dual instruction placement: static paragraph in prompt body + reinforcement in skill args.

3. **Force-advance code paths are untested**: All 6 existing force-advance cases have zero unit tests. The new implement case follows this pattern. We add test coverage for the new case but leave existing cases untested (out of scope for this change).

4. **`get_current_impl_phase()` with deferred tasks**: This function looks for `- [ ]` to find the current phase. If all remaining tasks in a phase are `- [-]`, it skips to the next phase — this is correct behavior (the phase is "done" from the orchestrator's perspective).

5. **Deferred tasks in GitHub sync**: `[REV6]` Revised — `_gh_parse_tasks()` regex expanded to `([\ x-])`. Deferred tasks are parsed but NOT created as issues (`gh_create_task_issues` skips them). They ARE rendered in the epic body with strikethrough (`~~desc~~ *(deferred)*`, no checkbox to prevent accidental GFM toggle). `gh_sync_done()` closes all issues from JSON on merge. If a task was `[ ]` (issue created) then later changed to `[-]`, the existing issue remains open until merge-time cleanup.

6. **Security-review tooling mismatch (pre-existing)**: `PHASE_TOOLS[security-review]="Read,Glob,Grep"` at `autopilot.sh:75` but the prompt asks the model to append markers, fix code, and commit. Adding deferred-task awareness doesn't make this worse. Not addressed in this change.

---

## `[REV3]` Repercussions Analysis — Consolidated Findings

### CRITICAL Issues — All Fixed in REV3

| # | Issue | Location | Fix |
|---|-------|----------|-----|
| C1 | `in_phase=[[ "$phase_num" == "$stuck_phase" ]]` is invalid bash — crashes under `set -euo pipefail` | REV2 pseudocode line 381 | `[REV3]` Rewritten: `if [[ "$phase_num" == "$stuck_phase" ]]; then in_phase=true; elif $in_phase; then in_phase=false; fi` — matches `count_phase_incomplete()` pattern at `autopilot-lib.sh:326-329` |
| C2 | `in_phase` never reset to `false` when entering non-stuck phase — defers ALL phases after stuck one | REV2 pseudocode lines 379-388 | `[REV3]` Fixed: `elif $in_phase; then in_phase=false` resets on phase boundary exit |
| C3 | `autopilot-validate.sh` not in `install.sh` copy loop — installed autopilots crash on `source: file not found` | `install.sh:116` | `[REV3]` Added to the `for script in ...` list |
| C4 | `$TARGET_REPO` variable doesn't exist in `install.sh` — expands to empty, writes to wrong path | REV2 plan references | `[REV3]` Replaced with bare relative paths: `"docs/specs/epics/TEMPLATE-epic.md"` matching `install.sh` convention |

### HIGH Issues — Fixed or Addressed in REV3

| # | Issue | Location | Resolution |
|---|-------|----------|------------|
| H1 | `gh_sync_done()` closes deferred tasks as "Done" | `autopilot-github-sync.sh:258-289` | `[REV6]` Resolved: deferred tasks have no GitHub issues created (`gh_create_task_issues` skips `checked == "-"`). `gh_sync_done()` closes from JSON cache — no deferred entries exist. If a task was `[ ]` (issue created) then later changed to `[-]`, the orphaned issue is closed at merge-time cleanup. |
| H2 | `gh_update_epic_body()` renders `[-]` as `[ ]` | `autopilot-github-sync.sh:197-201` | `[REV6]` Resolved: deferred tasks now rendered as `- ~~[NNN-P1.1] desc~~ *(deferred)*` — strikethrough, no checkbox. Prevents accidental GFM toggle on GitHub. |
| H3 | Review prompt weakened for normal case — model wastes time checking for deferred tasks that don't exist | REV2 plan line 419-424 | `[REV3]` Fixed: use conditional prompt injection in `run_phase()`. Base `prompt_review()` unchanged. Deferred awareness appended only when `deferred_count > 0`. |
| H4 | "None" dependency detection too aggressive — `[Nn]one` matches substrings | REV2 plan line 503 | `[REV3]` Fixed: tightened to `^[[:space:]]*[Nn]one([[:space:]]|$)` — matches "None" only as first word on a line |

### MEDIUM Issues — Fixed or Accepted

| # | Issue | Location | Resolution |
|---|-------|----------|------------|
| M1 | Cascading deferral burns tokens — worst case 15 wasted Claude invocations | Retry loop interaction | `[REV3]` Fixed: `consecutive_deferred` counter stops pipeline at 2 consecutive deferred phases (~4 iterations earlier than `MAX_TOTAL_ITERATIONS=30`) |
| M2 | Empty `stuck_phase` guard missing — infinite loop if `get_current_impl_phase()` returns empty | Force-advance pseudocode | `[REV3]` Fixed: `if [[ -z "$stuck_phase" ]]; then log ERROR ...; return 1; fi` |
| M3 | Security-review tooling mismatch (pre-existing) | `autopilot.sh:75` | Accepted: pre-existing issue, not addressed in this change |
| M4 | `spec_dir` path discrepancy (pre-existing) | `autopilot-prompts.sh:414` vs `autopilot.sh:210` | Accepted: pre-existing issue. The `prompt_security_review()` path `${repo_root}/.specify/specs/${short_name}` differs from `run_phase()` path `$repo_root/specs/$short_name`. Not addressed in this change. |

### LOW / No Issues — Confirmed Safe

| # | Item | Verdict |
|---|------|---------|
| `- [-]` regex safety | `[REV6]` Confirmed safe — `-` at end of bracket expression `[\ x-]` is literal per POSIX. Verified on macOS Darwin 24.6.0. `grep -c '^\- \[-\]'` works correctly with `^` anchor preventing mid-line false positives. | OK |
| sed portability | Confirmed portable — `\[ \]` escaping works identically on BSD and GNU sed. Existing codebase uses the same pattern. | OK |
| `- [-]` vs `- [~]` choice | `[REV6]` `- [-]` is the better choice — broader ecosystem recognition (Obsidian, community momentum), better visual clarity, equivalent regex safety. | OK |
| String replacement `${line/- \[ \]/- [-]}` | Works correctly — brackets need escaping in bash parameter expansion and the plan does this right. | OK |
| tmpfile data loss risk | No risk — follows existing codebase atomic write pattern (`: > .tmp`, write, `mv`). `[REV3]` Added explicit truncation before loop. | OK |
| VERSION bump correctness | `0.7.1` → `0.8.0` is correct semver minor bump. String comparison in `install.sh` handles it correctly. | OK |
| Template `../prd.md` link | Acceptable — consistent with directory convention enforced by `list_epics()`. | OK |
| Existing test breakage | No existing tests break from any proposed change. | OK |
| `detect_state()` all-deferred edge case | REV2 fix `complete + deferred > 0` is correct. Verified across 4 scenarios with `[-]` marker. | OK |
| `get_current_impl_phase()` with deferred | Functions correctly — `[-]` lines don't match `^-\ \[\ \]`, so deferred phases are skipped. This is correct behavior. | OK |
| Partial dependency note detection | Current regex matches all 3 real-world uses. No variant phrasing exists in the codebase. | OK |
| Performance of dependency validation | Sub-100ms for 10 epic files — negligible vs `claude -p` cost. | OK |
| `set -euo pipefail` propagation | Confirmed: propagates into sourced scripts (same shell process). Every sourced script redundantly declares `set -euo pipefail` at top (convention). New `autopilot-validate.sh` follows this convention. | OK |
| Subagent prompt leakage for deferred | NOT a risk. Parent session is the gatekeeper. Deferred instruction goes in main prompt body, not subagent block. | OK |
| `[REV6]` sed inside code fences | The force-advance `sed` command matches `- [ ]` inside markdown code fences (triple-backtick blocks). In practice, `tasks.md` files contain only task lists and HTML comments — no code fences with checkbox-like text. Theoretical concern, not practical. | OK |
| `[REV6]` Pre-existing `echo -e` usages | `autopilot.sh` lines 655, 662, 678, 700 use `echo -e` for existing force-advance markers. These are pre-existing and out of scope for this change. The bash built-in `echo` handles `-e` correctly under `#!/usr/bin/env bash`, but new code uses `printf` for POSIX portability. | OK |

---

## `[REV3]` Summary of Changes from REV2

8 changes total (6 bug fixes, 1 addition, 1 scope clarification):

| # | Change | Type | Detail |
|---|--------|------|--------|
| 1 | Fix scoped deferral bash syntax | Bug fix (C1) | `in_phase=[[ ... ]]` → `if [[ ... ]]; then in_phase=true` |
| 2 | Fix phase boundary reset in deferral loop | Bug fix (C2) | Add `elif $in_phase; then in_phase=false` |
| 3 | Add `autopilot-validate.sh` to install.sh copy loop | Bug fix (C3) | Without this, installed autopilots crash |
| 4 | Use bare relative paths in install.sh | Bug fix (C4) | `$TARGET_REPO` → `"docs/specs/epics/..."` |
| 5 | Conditional review prompt injection | Bug fix (H3) | Base prompt unchanged; deferred awareness only when `deferred_count > 0` |
| 6 | Tighten "None" dependency regex | Bug fix (H4) | `[Nn]one` → `^[[:space:]]*[Nn]one([[:space:]]|$)` |
| 7 | Add empty `stuck_phase` guard | Addition (M2) | 3 lines, prevents infinite loop |
| 8 | Add cascading deferral circuit breaker | Addition (M1) | `consecutive_deferred` counter, stops at 2 |

**Removed from REV2**: All references to `epic-[0-9]{3}[a-z]*` regex extension, `common.sh` changes, argument parser changes for alphanumeric epic IDs. The dependency regex stays as `epic-[0-9]{3}` (standard 3-digit only).

---

## `[REV4]` Summary of Changes from REV3

1 change (scope reduction based on second-round repercussions analysis):

| # | Change | Type | Detail |
|---|--------|------|--------|
| 1 | Narrow frontmatter validation to `epic_id` and `status` only | Scope reduction | Exhaustive code trace confirmed `created` and `project` are never parsed by any orchestrator function. Downgraded from ERROR to WARN. `document` and `version` removed from validation entirely (not consumed by any code). |

**Design changes investigated and rejected in REV4:**

| Item | Proposal | Verdict | Reason |
|------|----------|---------|--------|
| 6 | Scope force-advance to current phase only | **Dropped** | Implement prompt says "all tasks" — orchestrator has no per-phase retry concept. Per-phase deferral causes cascading failures when phases depend on each other. Global deferral is clearer. |
| 7 | Add `--no-validate` bypass flag | **Dropped** | Existing blocking/non-blocking split is sufficient. Structural checks block (justified — prevents garbage specs). Dependency checks warn (non-blocking by default). `--no-validate` would bypass both indiscriminately. |
| 9 | Classify soft vs hard dependencies via keyword parsing | **Dropped** | Default mode is already non-blocking (all deps produce warnings). `--strict-deps` is opt-in. Keyword parsing adds fragility for a distinction that the non-blocking default already handles naturally. |
| 10 | Expand `_gh_parse_tasks()` regex to `[\ x-]` | **Dropped** | Causes positional key collisions in task-issue JSON mapping. GitHub Markdown doesn't support `[-]` checkboxes. Orphaned issues self-heal via `gh_sync_done()` at merge. |
| 11 | Refactor `list_epics()` into shared `_build_epic_index()` | **Dropped** | Introduces `declare -gA` with no codebase precedent, breaks test stubs, adds global mutable state. Dependency validator simply calls `list_epics()` directly and parses into local arrays — zero changes to existing code. |

---

## `[REV5]` Summary of Changes from REV4

2 additions (1 documentation, 1 feature completion):

| # | Change | Type | Detail |
|---|--------|------|--------|
| 1 | Document deferred marker syntax rationale | Documentation | `[REV6]` Updated: switched from `- [~]` to `- [-]` based on ecosystem analysis. `- [-]` has broader adoption (Obsidian, GitHub community). On GitHub both render as plain text (no checkbox). |
| 2 | Add cross-epic deferred task accumulation check in `run_finalize()` | Addition | 12 lines in `autopilot-finalize.sh`. Emits `log WARN` with total deferred count across all epics. Runs once at project end (not per-epic). Closes the visibility gap between per-epic summaries and project-level awareness. |

**Design changes investigated and rejected in REV5:**

| Item | Proposal | Verdict | Reason |
|------|----------|---------|--------|
| 2 | Move deferred awareness into `prompt_review()` itself | **Dropped** | Breaks the architectural invariant that all 16 prompt functions are pure text generators (zero filesystem reads). REV3 conditional injection in `run_phase()` is the correct pattern — keeps state-awareness in the orchestrator where it belongs. The "ordering" argument is invalid: the LLM receives the complete prompt atomically via string concatenation before `claude -p`. |
| 3 | Strengthen security review prompt with inline deferred task listing | **Dropped** | The proposed `grep \| sed` pipeline is unsafe under `set -euo pipefail`. The `spec_dir` path inside `prompt_security_review()` (`${repo_root}/.specify/specs/`) differs from `run_phase()` path (`$repo_root/specs/`) — pre-existing M4 discrepancy means grep would target the wrong path. The model has Read/Grep tool access and can discover deferred tasks itself. The generic REV2 instruction is sufficient. |
| 5 | Specify exact `--help` echo lines for new flags | **Dropped** | Already covered at Implementation Order Step 4 (line 847): "Update `--help` output in `parse_args()` for `--strict-deps` and `--allow-deferred`". The implementation pattern is self-evident from the existing 7 inline echo statements in `parse_args()`. Redundant. |
| 6 | Make FR bullet counting recursive under `###` subsections with EARS-pattern keywords | **Dropped** | False-positive concern unfounded — the natural implementation counts all `- ` lines between `## Functional Requirements` and the next `## ` heading, which naturally includes bullets under `###` subsections (only `##` terminates the section). EARS-pattern keyword matching (`The system shall`, `When`, `If`) introduces false negatives on legitimate FR bullets that don't use those patterns. This is a WARNING-only check; even a false positive is harmless. |

---

## `[REV6]` Summary of Changes from REV5

7 changes (1 syntax switch, 3 functional additions, 2 bug fixes, 1 scope expansion):

| # | Change | Type | Detail |
|---|--------|------|--------|
| 1 | Switch deferred marker from `- [~]` to `- [-]` | Syntax change | Broader ecosystem recognition (Obsidian Tasks, Minimal theme, GitHub community #19199). Equivalent regex safety — `-` at end of bracket expression is literal per POSIX. All grep/sed/bash regex patterns updated. |
| 2 | Add static deferred-skip paragraph to `prompt_implement()` | Addition | Inserted after CLAUDE.md line (line 372), before subagent block. Ensures Claude understands `[-]` semantics before dispatching any work. Complements the existing `args` instruction. |
| 3 | Add conditional deferred injection for `prompt_security_review()` | Addition | Same pattern as REV3 review injection. Appends at call site in `run_phase()` when `deferred_count > 0`. Warns about security gaps from omitted functionality. |
| 4 | Simplify GitHub sync to "skip deferred, render in body" | Scope change | Replaces REV2 "keep invisible" approach. **Reconsiders REV4 item 10** (was rejected due to "positional key collisions"). `_gh_parse_tasks()` regex expanded to `([\ x-])`. Deferred tasks parsed but skipped at issue creation (`[[ "$checked" == "-" ]] && continue` in `gh_create_task_issues()`), eliminating the collision concern. Rendered with strikethrough in epic body (no checkbox — prevents accidental GFM toggle). Zero new API calls, no labels, no board changes. |
| 5 | Add cross-epic deferred awareness to `_validate_dependencies()` | Addition | When a dependency IS merged, checks its `tasks.md` for `[-]` lines. Warns with count + first 3 task descriptions. WARN only, non-blocking. Handles edge cases: pre-`[-]` epics, missing tasks.md, placeholder branches. |
| 6 | Replace `echo -e` with `printf` in force-advance marker | Bug fix | `echo -e` is not POSIX-portable — macOS `/bin/echo` outputs literal `-e \n...`. `printf` works identically everywhere. Applies to the `<!-- FORCE_DEFERRED -->` marker append. |
| 7 | Cap deferred task warnings at count + first 3 | Bug fix | `head -5` doesn't communicate total count. Changed to show `$dep_deferred deferred task(s):` header + first 3 via `head -3` + `"... and N more"` when total > 3. |

**Design changes investigated and rejected in REV6:**

| Item | Proposal | Verdict | Reason |
|------|----------|---------|--------|
| 1 | Add "deferred" label to GitHub issues | **Dropped** | Requires label creation, `gh_try` wrapping, board status decision. 5-6 touch points vs 3 for "skip and render" approach. Deferred tasks don't need individual GitHub issue tracking — they're deferred precisely because they're not being worked on. |
| 2 | Render deferred as `- [ ] ~~desc~~` in epic body | **Dropped** | `- [ ]` creates interactive GFM checkbox on GitHub. Users clicking it would modify the issue body, desynchronizing from local `tasks.md`. Using no checkbox prefix with strikethrough avoids this entirely. |
| 3 | Use `- [~]` (GitLab "inapplicable") | **Dropped** | Not recognized by Obsidian or any markdown tool besides GitLab. `- [-]` has broader grassroots adoption and is the most likely candidate for standardization. |
| 4 | Full GitHub sync with board status column for deferred | **Dropped** | Requires changes to `_gh_phase_to_status()`, `GH_STATUS_OPT`, and project setup. Disproportionate complexity for an opt-in, rare code path. |

---

## `[REV7]` Summary of Changes from REV6

1 change (consistency fix based on repercussions analysis):

| # | Change | Type | Detail |
|---|--------|------|--------|
| 1 | Use `$TEMPLATE_DEST` variable for template install destination | Consistency fix | All file copy/write destinations in `install.sh` use dedicated variables (`$DEST`, `$SKILL_DEST`, `$VERSION_FILE`). The template copy step now uses `TEMPLATE_DEST="docs/specs/epics"` to follow this convention. Functionally identical — resolves to the same bare relative path. Zero breaking change risk. |
