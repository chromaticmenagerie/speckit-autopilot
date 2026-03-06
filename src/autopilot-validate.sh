#!/usr/bin/env bash
# autopilot-validate.sh — Pre-specify validation for epic files.
# Sourced by autopilot.sh — not run standalone.
# Validates epic quality before spending tokens on specification.

set -euo pipefail

# ─── Main Entry Point ───────────────────────────────────────────────────────

# Validate an epic file before processing.
# Returns 0 if valid, 1 if blocking errors found.
validate_epic() {
    local repo_root="$1"
    local epic_num="$2"
    local epic_file="$3"

    log INFO "Validating epic $epic_num: $epic_file"

    local errors=0
    local warnings=0

    # Run all validation checks
    local fe fw
    _validate_frontmatter "$epic_file" "$epic_num"
    fe=$?
    errors=$((errors + fe))

    local se
    _validate_sections "$epic_file"
    se=$?
    errors=$((errors + se))

    local de
    _validate_dependencies "$repo_root" "$epic_file" "$epic_num"
    de=$?
    errors=$((errors + de))

    _validate_content_quality "$epic_file"

    if [[ $errors -gt 0 ]]; then
        log ERROR "Epic $epic_num has $errors blocking error(s) — fix before proceeding"
        return 1
    fi

    log OK "Epic $epic_num validation passed"
    return 0
}

# ─── Frontmatter Validation ─────────────────────────────────────────────────

_validate_frontmatter() {
    local epic_file="$1"
    local epic_num="$2"
    local errors=0

    local epic_id="" status="" branch="" created="" project=""
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
            elif [[ "$line" =~ ^created:\ *(.+) ]]; then
                created="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^project:\ *(.+) ]]; then
                project="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$epic_file"

    # ERROR checks (blocking — fields the orchestrator depends on)

    # epic_id: must match epic-NNN pattern (standard 3-digit)
    if [[ -z "$epic_id" ]]; then
        log ERROR "Frontmatter: epic_id is missing"
        errors=$((errors + 1))
    elif [[ ! "$epic_id" =~ ^epic-[0-9]{3}$ ]]; then
        log ERROR "Frontmatter: epic_id '$epic_id' does not match epic-NNN pattern (3-digit required)"
        errors=$((errors + 1))
    fi

    # status: must be a valid value
    if [[ -z "$status" ]]; then
        log ERROR "Frontmatter: status is missing"
        errors=$((errors + 1))
    else
        case "$status" in
            draft|not-started|in-progress|merged) ;;
            *)
                log ERROR "Frontmatter: status '$status' is not valid (expected: draft, not-started, in-progress, merged)"
                errors=$((errors + 1))
                ;;
        esac
    fi

    # WARN checks (non-blocking)

    # branch: accept placeholder comments and empty values
    if [[ -n "$branch" ]]; then
        if [[ ! "$branch" =~ ^# ]]; then
            # Has a real branch value — no warning needed
            :
        fi
        # If starts with #, it's a placeholder comment — fine
    fi

    # created: warn if present but not valid date
    if [[ -n "$created" ]] && [[ ! "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log WARN "Frontmatter: created '$created' is not a valid YYYY-MM-DD date"
    fi

    # project: warn if present but empty
    if [[ -z "$project" ]]; then
        log WARN "Frontmatter: project field is missing or empty (metadata only — not blocking)"
    fi

    return $errors
}

# ─── Section Validation ─────────────────────────────────────────────────────

_validate_sections() {
    local epic_file="$1"
    local errors=0

    # Required sections (ERROR — blocks)
    local -a required_sections=("Functional Requirements" "Acceptance Criteria" "Dependencies")
    for section in "${required_sections[@]}"; do
        if ! grep -q "^## ${section}" "$epic_file" 2>/dev/null; then
            log ERROR "Missing required section: ## $section"
            errors=$((errors + 1))
        fi
    done

    # Optional sections (WARN — non-blocking)
    local -a optional_sections=("Out of Scope" "Self-Containment Checklist" "Implementation Hints")
    for section in "${optional_sections[@]}"; do
        if ! grep -q "^## ${section}" "$epic_file" 2>/dev/null; then
            log WARN "Missing optional section: ## $section"
        fi
    done

    return $errors
}

# ─── Dependency Validation ──────────────────────────────────────────────────

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
            # Detect "None" dependencies (foundational epics)
            # Tightened regex: match "None" only as the first word on a line
            if [[ "$line" =~ ^[[:space:]]*[Nn]one([[:space:]]|$) ]]; then
                return 0  # No dependencies to check
            fi

            # Detect partial dependency notes
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

                # Find the referenced epic file
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

                # Parse branch and status from referenced epic's YAML
                local ref_short_name="" ref_yaml_status=""
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
                    if $in_fm && [[ "$fmline" =~ ^status:\ *(.+) ]]; then
                        ref_yaml_status="${BASH_REMATCH[1]}"
                    fi
                done < "$ref_file"

                if ! is_epic_merged "$repo_root" "$ref_short_name" "$ref_yaml_status"; then
                    local msg="Epic $epic_num depends on $ref which is not yet merged"
                    # Partial dependency note downgrades errors to warnings
                    if ${STRICT_DEPS:-false} && ! $has_partial_note; then
                        log ERROR "$msg"
                        errors=$((errors + 1))
                    else
                        log WARN "$msg"
                        warnings=$((warnings + 1))
                    fi
                else
                    # Check merged dependency for deferred tasks
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

# ─── Content Quality (Warnings only) ────────────────────────────────────────

_validate_content_quality() {
    local epic_file="$1"

    # Count FR bullets (all "- " lines between ## Functional Requirements and next ##)
    local in_fr=false
    local fr_count=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+Functional[[:space:]]+Requirements ]]; then
            in_fr=true
            continue
        fi
        if $in_fr && [[ "$line" =~ ^##[[:space:]] ]]; then
            break
        fi
        if $in_fr && [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
            fr_count=$((fr_count + 1))
        fi
    done < "$epic_file"

    if [[ "$fr_count" -lt 3 ]]; then
        log WARN "Content quality: Functional Requirements has fewer than 3 bullet points ($fr_count found)"
    fi

    # Count AC checkboxes
    local in_ac=false
    local ac_checkbox_count=0
    local ac_non_checkbox=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+Acceptance[[:space:]]+Criteria ]]; then
            in_ac=true
            continue
        fi
        if $in_ac && [[ "$line" =~ ^##[[:space:]] ]]; then
            break
        fi
        if $in_ac && [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]]\] ]]; then
            ac_checkbox_count=$((ac_checkbox_count + 1))
        elif $in_ac && [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]] && [[ ! "$line" =~ ^[[:space:]]*-[[:space:]]\[ ]]; then
            ac_non_checkbox=$((ac_non_checkbox + 1))
        fi
    done < "$epic_file"

    if [[ "$ac_checkbox_count" -eq 0 ]]; then
        log WARN "Content quality: Acceptance Criteria has zero checkboxes (- [ ])"
    fi

    if [[ "$ac_non_checkbox" -gt 0 ]]; then
        log WARN "Content quality: Acceptance Criteria has $ac_non_checkbox non-checkbox items"
    fi

    # Check for dependency references to non-existent epic files
    # (already handled in _validate_dependencies, this is a no-op here)
}
