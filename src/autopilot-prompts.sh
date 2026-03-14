#!/usr/bin/env bash
# autopilot-prompts.sh — Phase-specific prompt templates for claude -p invocations.
# Each function outputs a self-contained prompt string.
# Language-agnostic: all project-specific conventions are read from CLAUDE.md.

set -euo pipefail

# ─── Shared preamble ────────────────────────────────────────────────────────

_preamble() {
    local epic_num="$1" title="$2" repo_root="$3"
    cat <<PREAMBLE
IMPORTANT: Read .specify/memory/constitution.md and .specify/memory/architecture.md FIRST.
Internalize all principles, prohibitions, and current architecture. They are non-negotiable.

You are working on epic ${epic_num}: "${title}".
Working directory: ${repo_root}
PREAMBLE
}

# ─── Phase: Specify ─────────────────────────────────────────────────────────

prompt_specify() {
    local epic_num="$1" title="$2" epic_file="$3" repo_root="$4"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Read the epic file at ${epic_file} — extract ALL functional requirements and context.

Then invoke the Skill tool exactly once:
  skill = "speckit.specify"
  args  = the full epic description and functional requirements from the epic file

If the skill asks clarification questions, answer them AUTONOMOUSLY:
- Cross-reference with the epic requirements and constitution principles
- Always choose the option most aligned with the constitution
- Provide a brief one-line rationale for each choice
- Never ask the user — decide based on the available context

After the skill completes, verify that spec.md was created in the specs/ directory.

When the skill creates a feature branch, ensure it uses the epic number ${epic_num}
as the branch prefix (e.g., ${epic_num}-feature-name). This is required for the
orchestrator's state detection to work correctly.

After the skill completes and spec.md exists, commit the specification:
  git add specs/*/spec.md
  git commit -m "docs(${epic_num}): initial specification"
EOF
}

# ─── Phase: Clarify ─────────────────────────────────────────────────────────

prompt_clarify() {
    local epic_num="$1" title="$2" epic_file="$3" repo_root="$4" spec_dir="$5"
    local round="${6:-1}" max_rounds="${7:-8}"
    local clarify_total="${8:-}" clarify_cycle_num="${9:-}"
    local spec_dir_name
    spec_dir_name="$(basename "$spec_dir")"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Read the epic file at ${epic_file} for reference context, then read ${spec_dir}/spec.md.

If \`<!-- VERIFY_FINDINGS: ... -->\` comments exist in spec.md from a previous
clarify-verify rejection, prioritise addressing those issues first. After addressing
them, remove the resolved VERIFY_FINDINGS comment block. Then continue your normal
ambiguity scan.

Invoke the Skill tool ONCE:
  skill = "speckit.clarify"
  args  = "as a senior developer"

When the skill asks questions, answer AUTONOMOUSLY:
- Cross-reference with the epic file requirements and constitution
- Choose the option most aligned with constitution principles
- If equally valid, prefer the simpler approach (Constitution Principle VI)
- Provide a brief rationale for each answer

After the skill completes, carefully check the observations/findings reported:

If ZERO observations (the skill reports no issues or underspecified areas):
  1. Append this exact marker at the END of spec.md on its own line:
     <!-- CLARIFY_COMPLETE -->
  2. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "docs(${epic_num}): clarify round ${round}/${max_rounds}$([ -n "${clarify_total}" ] && echo " (cycle ${clarify_cycle_num}, total ${clarify_total})") — zero observations"

If observations WERE found (the skill reported issues, questions, or underspecified areas):
  1. Ensure all fixes and answers have been applied to spec.md
  2. Do NOT add <!-- CLARIFY_COMPLETE -->
  3. Commit fixes:
     git add specs/${spec_dir_name}/
     git commit -m "fix(${epic_num}): clarify round ${round}/${max_rounds}$([ -n "${clarify_total}" ] && echo " (cycle ${clarify_cycle_num}, total ${clarify_total})") — resolve observations"

The orchestrator will re-run /speckit.clarify in a fresh context until zero observations
are reported, up to a maximum of 8 rounds.
EOF
}

# ─── Phase: Clarify-Verify (fresh-context independent verification) ─────────

prompt_clarify_verify() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4"
    local spec_dir_name
    spec_dir_name="$(basename "$spec_dir")"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

The clarify phase has marked spec.md as complete. Your job is to INDEPENDENTLY
verify the spec quality in a fresh context — without invoking any speckit skills.

Read ${spec_dir}/spec.md carefully. Check for:
- Underspecified requirements (vague terms like "should handle", "as needed", "etc.")
- Missing acceptance criteria for user stories
- Ambiguous success metrics
- Undefined error handling behaviour
- Missing edge cases for key requirements
- Requirements that conflict with .specify/memory/constitution.md principles
- For any regex pattern in the spec, verify it includes 3+ test strings showing expected match/no-match behavior
- For any validation rule with pattern matching, verify concrete examples are provided

If the spec is COMPREHENSIVE (zero significant issues found):
  1. Append this exact marker at the END of spec.md on its own line:
     <!-- CLARIFY_VERIFIED -->
  2. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "docs(${epic_num}): clarify verified — spec is comprehensive"

If SIGNIFICANT issues are found:
  1. Remove the <!-- CLARIFY_COMPLETE --> marker from spec.md
  2. Add a comment block at the end of spec.md listing the issues found:
     <!-- VERIFY_FINDINGS: issue1; issue2; issue3 -->
  3. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "fix(${epic_num}): clarify-verify found issues — returning to clarify"

The orchestrator will loop back to the clarify phase if you remove the marker.
Minor style or formatting issues do NOT count — only report substantive gaps.
EOF
}

# ─── Phase: Plan ─────────────────────────────────────────────────────────────

prompt_plan() {
    local epic_num="$1" title="$2" repo_root="$3"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Invoke the Skill tool:
  skill = "speckit.plan"

The skill will read the spec and generate design artifacts (plan.md, research.md, data-model.md, contracts/, quickstart.md).

After the skill completes, verify that plan.md was created.

Then perform a senior developer critique of the plan:
- Check for constitution violations
- Check task ordering and dependency issues
- Check for missing test coverage
- Check file size / complexity concerns (per CLAUDE.md conventions)
Apply any fixes directly to the artifacts.

After the skill completes and plan artifacts exist, commit them:
  git add specs/*/
  git commit -m "docs(${epic_num}): planning artifacts"
EOF
}

# ─── Phase: Tasks ────────────────────────────────────────────────────────────

prompt_tasks() {
    local epic_num="$1" title="$2" repo_root="$3"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Invoke the Skill tool:
  skill = "speckit.tasks"

The skill will read the plan and spec to generate tasks.md with dependency-ordered, phased tasks.

After the skill completes, verify that tasks.md was created and contains Phase headers and task checkboxes.

After the skill completes and tasks.md exists, commit it:
  git add specs/*/tasks.md
  git commit -m "docs(${epic_num}): task breakdown"
EOF
}

# ─── Phase: Analyze (fix mode) ─────────────────────────────────────────────

prompt_analyze() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4"
    local round="${5:-1}" max_rounds="${6:-5}"
    local spec_dir_name
    spec_dir_name="$(basename "$spec_dir")"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Invoke the Skill tool ONCE:
  skill = "speckit.analyze"
  args  = "as a senior developer"

Review the analysis report carefully.

Additionally, check all spec artifacts for regex patterns:
- For any regex in spec.md, plan.md, or tasks.md, ensure 3+ test strings
  are provided showing expected match/no-match behavior
- If regex patterns lack test cases, add them as a finding to fix

If ZERO issues are found (no CRITICAL, HIGH, MEDIUM, or LOW findings):
  1. Append this exact marker at the END of tasks.md on its own line:
     <!-- ANALYZED -->
  2. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "docs(${epic_num}): analyze round ${round}/${max_rounds} — artifacts ready"

If ANY issues are found:
  1. Fix ALL issues in the artifacts (spec.md, plan.md, tasks.md) directly
  2. Do NOT add <!-- ANALYZED -->
  3. Append this exact marker at the END of tasks.md on its own line:
     <!-- FIXES APPLIED -->
  4. Commit fixes:
     git add specs/${spec_dir_name}/
     git commit -m "fix(${epic_num}): analyze round ${round}/${max_rounds} — resolve findings"

The orchestrator will re-run /speckit.analyze in a fresh context until zero issues
are reported, up to a maximum of 5 rounds.
EOF
}

# ─── Phase: Analyze-Verify (fresh-context verification) ───────────────────

prompt_analyze_verify() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4"
    local round="${5:-1}" max_rounds="${6:-5}"
    local spec_dir_name
    spec_dir_name="$(basename "$spec_dir")"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Previous analysis found issues which were fixed.
Run /speckit.analyze ONCE to verify the fixes.

Invoke the Skill tool ONCE:
  skill = "speckit.analyze"
  args  = "as a senior developer"

If ANY issues remain:
  1. Remove the <!-- FIXES APPLIED --> line from tasks.md
  2. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "fix(${epic_num}): analyze-verify round ${round}/${max_rounds} — issues remain"
  The orchestrator will loop back to full analyze in a fresh context.

If zero issues:
  1. Replace <!-- FIXES APPLIED --> with <!-- ANALYZED --> in tasks.md
  2. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "docs(${epic_num}): analyze round ${round}/${max_rounds} — artifacts ready"
EOF
}

# ─── Phase: Design Read (extract design context from .pen file) ──────────

prompt_design_read() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4" pen_file="$5"
    local pen_structure="${6:-}"
    local spec_dir_name
    spec_dir_name="$(basename "$spec_dir")"
    cat <<'SCHEMA_EOF'
── .pen Schema Reference ──
Top-level keys: "version", "children" (array of root frames), "variables" (design tokens).
6 node types: frame, text, icon_font, rectangle, ellipse, ref.
- frame: container with optional layout ("vertical" = column, absent = row), gap, padding,
  justifyContent, alignItems, fill, stroke, cornerRadius, effect. Has children array.
- text: has content (string), fontSize, fontWeight, fontFamily, fill, textAlign, lineHeight.
- icon_font: has iconFontName, iconFontFamily (e.g. "lucide"), width, height, fill.
- rectangle: shape with fill, stroke, cornerRadius, width, height.
- ellipse: circle/oval with fill, width, height.
- ref: component instance — "ref" field points to id of a node with "reusable": true.
Variables: top-level "variables" object maps "$--name" to {type, value}.
  In node properties, "$--name" means resolve from variables map.
  Types: "color", "string", "number".
Reusable components: any node with "reusable": true is a component definition.
Fill types: hex string ("#D4213D"), variable ref ("$--primary"),
  gradient object ({type:"gradient", gradientType, rotation, colors:[]}),
  image object ({type:"image", url, mode:"fill"|"fit"}).
Layout maps to CSS flexbox: layout:"vertical" = flex-direction:column,
  gap/padding/justifyContent/alignItems are direct CSS equivalents.
Sizing: number = px, "fill_container" = flex:1, "fit_content(N)" = shrink-wrap with min N.
SCHEMA_EOF
    cat <<EOF

$(_preamble "$epic_num" "$title" "$repo_root")

Also read the spec at: ${spec_dir}/spec.md

The .pen file is plain JSON (Pencil format). Use the schema reference above to parse it.

── Extraction Instructions ──
Extract and organize the following from the .pen JSON:

1. SCREEN INVENTORY: All top-level frames (direct children of root "children" array).
   For each: name, width, height, viewport type (Desktop if width>=1024,
   Tablet if 768-1023, Mobile if <768, or infer from name prefixes like "Mobile /").

2. DESIGN TOKENS: All entries from the top-level "variables" object.
   For each: token name (strip \$ prefix), type, value, CSS equivalent hint.

3. REUSABLE COMPONENTS: All nodes where "reusable" is true.
   For each: id, name, dimensions, key visual properties (fill, cornerRadius, etc.),
   and a brief description of children structure (2-3 lines max).

4. COMPONENT INSTANCES: All "ref" nodes found throughout the tree.
   For each: which component they reference, which screen they appear in, any overrides.

5. LAYOUT PATTERNS: Identify recurring layout structures across screens.
   Note flexDirection, gap, padding, justifyContent, alignItems values.
   Examples: centered card, sidebar+content, card grid, form stack, nav patterns.

6. SCREEN-TO-REQUIREMENT MAPPING: Cross-reference screen names with requirements
   and user stories in spec.md. Map each screen to relevant functional requirements.

EOF

    if [[ -n "$pen_structure" ]]; then
        cat <<PREPARSE

## Pre-extracted .pen Structure

The .pen file has been pre-parsed. The structural data below contains ALL screens (light, dark, desktop, tablet, mobile) with full component hierarchy. Use this data directly — do NOT attempt to read the .pen file.

<pen-structure>
${pen_structure}
</pen-structure>

Using the pre-extracted data above, produce the design-context.md file following the output format below. You still need to:
1. Name and describe layout patterns from the tree structure
2. Cross-reference screens with specs/${spec_dir_name}/spec.md for the Screen-to-Requirement Mapping
3. Write Implementation Notes (icon library, breakpoints, typography scale, color palette summary)
4. Enforce Theme Integration rules

PREPARSE
    else
        cat <<FALLBACK

Read the .pen file at: ${pen_file}
Extract ALL structural information following the extraction instructions above.

FALLBACK
    fi

    cat <<EOF
── Output ──
Write the extracted context to: ${spec_dir}/design-context.md

Use this structure:

# Design Context: Epic ${epic_num} — ${title}

## Screens
| Screen | Viewport | Dimensions | Description |
|--------|----------|------------|-------------|

## Design Tokens
| Token | Type | Value | CSS Equivalent |
|-------|------|-------|---------------|

## Reusable Components
### ComponentName (id: xxx)
- Dimensions: WxH
- Key properties: fill, cornerRadius, etc.
- Children: [brief structural description]

## Component Instance Map
| Instance Location | Component | Overrides |
|-------------------|-----------|-----------|

## Screen-to-Requirement Mapping
| Screen | Requirement | Acceptance Criteria |
|--------|-------------|-------------------|

## Layout Patterns
- Pattern name: description with key CSS/flex properties

## Implementation Notes
- Icon library and family used
- Responsive breakpoints detected
- Typography scale (font sizes, weights, families)
- Color palette summary (from tokens)
- Any other notable patterns

## Theme Integration
- ALL design tokens above MUST be mapped to a theme config file before any screens are built
- If the project already has CSS custom properties (check app.css, global.css, variables.css),
  extend them — do not create a duplicate file
- If the project uses Tailwind (check tailwind.config.*, CLAUDE.md), extend the Tailwind theme
- The theme config file is the ONLY place raw hex/color values should appear
- All component and page styles MUST reference variables (var(--token)) or Tailwind classes — never raw hex
- This is a hard rule: a color literal like #D4213D in a .svelte/.tsx/.vue file is a bug

After writing design-context.md, commit:
  git add specs/${spec_dir_name}/design-context.md
  git commit -m "docs(${epic_num}): extract design context from .pen file"
EOF
}

# ─── Phase: Implement (via /speckit.implement with subagent parallelism) ────

prompt_implement() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4"
    local current_phase="${5:-1}" total_phases="${6:-1}"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")
$(if [[ "$total_phases" -gt 1 ]]; then
cat <<SCOPE

SCOPE: Implement Phase $current_phase of $total_phases ONLY.
$(if [[ $current_phase -gt 1 ]]; then echo "Phases 1-$((current_phase-1)) are already complete."; else echo "This is the first phase."; fi)
Focus ONLY on Phase $current_phase tasks. Do NOT touch completed phases.
SCOPE
fi)

Read ALL design artifacts in ${spec_dir}/ to understand the full scope.
If ${spec_dir}/design-context.md exists, read it. It is the authoritative visual specification:
- Match design tokens EXACTLY — map to CSS custom properties or Tailwind config
- Implement ALL screens listed in the screen inventory
- Use the reusable components catalogue as your component decomposition guide
- Follow the layout patterns precisely (flex directions, gaps, padding, alignment)
- Use the specified icon library (check Implementation Notes section)
Also read CLAUDE.md for project conventions, reusable utilities, and patterns.

IMPORTANT: Tasks marked - [-] in tasks.md are DEFERRED. Skip them entirely —
do not implement them, do not mark them [x], do not create subagents for them.
Only process tasks marked - [ ] (incomplete).

When launching Task subagents for parallel [P] tasks, include this instruction
in each subagent prompt:
  "Before writing code, read .specify/memory/architecture.md for module
  dependencies and CLAUDE.md for reusable utilities and patterns.
  If specs/{name}/design-context.md exists, also read it for design token
  values, component structure, layout specifications, and the Theme Integration
  rules. Reference design tokens via CSS variables or Tailwind classes —
  never hardcode hex color values in component or page files."

Before marking a task [x], list each concrete deliverable in the task
description and verify each one separately. If the task says "A AND B",
verify A exists in code, then verify B exists in code. Only mark [x] if
ALL deliverables are confirmed.

Then invoke the Skill tool:
  skill = "speckit.implement"
  args  = "all tasks using subagents for parallel [P] tasks — IMPORTANT: tasks marked - [-] are deferred and MUST be skipped entirely, do not attempt to implement them"

The skill will:
- Read tasks.md and identify phases, dependencies, and [P] markers
- Dispatch independent [P] tasks as parallel subagents via the Task tool
- Execute sequential tasks in dependency order
- Follow strict TDD for each task (test first, implement, verify)
- Mark each task [x] in tasks.md after completion
- The skill does NOT commit — you will commit per-phase after verification below

After the skill completes, verify:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "  cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "  cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_LINT_CMD}"; fi)
$(if [[ "${HAS_FRONTEND:-false}" == "true" ]]; then cat <<'A11Y'

When working on frontend/UI components, apply WCAG 2.1 AA accessibility standards:
- All interactive elements must have aria-labels or accessible names
- Ensure color contrast meets 4.5:1 for normal text, 3:1 for large text
- All interactive flows must be keyboard-navigable
- Images must have meaningful alt text
A11Y
fi)

After tests and lint pass, commit changes grouped by implementation phase/user story.

Run: git status --short

Review the output. Then commit in phase-based groups — one commit per implementation phase or user story.
For each group:
  1. Stage only the files belonging to that phase/user story
  2. Run: git diff --cached --stat
  3. Verify the staged files match the phase scope
  4. If nothing was staged, skip to the next group
  5. Commit with format: <type>(${epic_num}): <phase/user-story description>

Example grouping (adapt to the actual tasks.md phases):
  - Phase 1 setup/types: git commit -m "feat(${epic_num}): setup types and project structure"
  - Phase 2 test stubs: git commit -m "test(${epic_num}): add test stubs for US1"
  - Phase 3 US1 implementation: git commit -m "feat(${epic_num}): implement US1 — <description>"
  - Phase 4 US2 implementation: git commit -m "feat(${epic_num}): implement US2 — <description>"

Use "feat" for new functionality, "test" for test files, "chore" for config/tooling.
Stage specific files or directories — never use "git add -A" or "git add ."
After all groups committed, verify: git status shows a clean working tree.
If any files still remain, investigate why they were not included in a phase group.
Stage them explicitly with a descriptive commit message — do NOT use "git add -A".
EOF
}

# ─── Phase: Security Review ───────────────────────────────────────────────────

prompt_security_review() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4" round="$5" max_rounds="$6"
    local spec_dir="${repo_root}/specs/${short_name}"

    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

You are performing a **security-focused code review** of the changes made for epic ${epic_num}: ${title}.
This is review round ${round} of ${max_rounds}.

Read ALL modified and new files in the specs directory and implementation.

## Security Checklist

Check every item below. For each finding, classify severity and whether it is auto-fixable:

Before reviewing, check tasks.md for any deferred tasks (- [-]). If deferred tasks exist,
note which functionality is NOT implemented and flag any security implications of the missing
code (e.g., missing authorization checks, missing input validation for deferred endpoints).

1. **Auth boundary**: Every endpoint/handler verifies the resource belongs to the requesting org/user. No IDOR vulnerabilities.
2. **Input validation**: No raw SQL concatenation, no unescaped HTML output, no unvalidated redirects or path traversal.
3. **Error handling**: No silently swallowed errors, no empty catch/recover blocks, no error responses leaking internal details.
4. **Secrets**: No hardcoded credentials, API keys, or tokens. No PII in log statements.
5. **RLS policy coverage**: Every new table with tenant-scoped data has Row Level Security policies.
6. **Migration safety**: Migrations are idempotent and can be re-run safely. No destructive operations without guards.
7. **Dependency security**: No new dependencies with known vulnerabilities.

## Actions

Scan all code against the checklist above. Then **append** a new round section to \`${spec_dir}/security-findings.md\` using the Write tool. The file already exists with a header — do NOT overwrite existing content, only APPEND.

**If ZERO findings** (all checks pass), append:

\`\`\`markdown
## Round ${round} (${round}/${max_rounds})

Verdict: PASS

All security checks passed. No findings.
\`\`\`

**If ANY findings**, append:

\`\`\`markdown
## Round ${round} (${round}/${max_rounds})

Verdict: FAIL

### 1. [title of finding]
- **Severity**: CRITICAL | HIGH | MEDIUM | LOW
- **Category**: auth-boundary | input-validation | error-handling | secrets | rls | migration | dependency
- **File**: path/to/file.go:42
- **Auto-fixable**: yes | no
- **Description**: What the issue is
- **Fix**: How to fix it
\`\`\`

Repeat the numbered finding block for each issue found.

Do NOT modify source code. Do NOT add HTML markers to tasks.md. Do NOT commit. **Append** ONLY to the findings file — do not overwrite existing content.
EOF
}

prompt_security_fix() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4" findings_file="$5"

    local findings_section=""
    if [[ -n "$findings_file" ]]; then
        findings_section="Read the security findings from: ${findings_file}"
    else
        findings_section="(no findings)"
    fi

    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

The security review found issues that need fixing.

${findings_section}

Instructions:
1. Read each finding carefully — understand the file and line referenced.
2. Read the relevant source files.
3. Fix all CRITICAL and HIGH severity auto-fixable issues — these are mandatory.
4. Fix MEDIUM auto-fixable issues if straightforward (< 5 lines changed).
5. Skip LOW severity issues.
6. For non-auto-fixable items: add a \`// SECURITY: <description>\` comment at the relevant location.
7. After fixing, verify:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_LINT_CMD}"; fi)
8. Commit all fixes:
   git add <specific files>
   git commit -m "security-fix(${epic_num}): resolve security findings"
9. Verify clean working tree: git status

Do NOT add any HTML markers to tasks.md.
EOF
}

prompt_security_verify() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4" round="$5" max_rounds="$6"
    local spec_dir="${repo_root}/specs/${short_name}"
    local findings_file="${spec_dir}/security-findings.md"

    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

# Security Verify — Cycle ${round}/${max_rounds}

You are independently verifying that security fixes from the previous review round
were correctly applied. Your mandate is NOT "find everything" — it is
"confirm the work is done."

## Instructions

1. Read the security findings file: ${findings_file}
   Identify all findings from the latest Round section.

2. For each finding, check the current code (use git diff HEAD~1 or read files directly):
   - **RESOLVED**: Fix correctly closes the vulnerability. Cite commit/file:line evidence.
   - **UNRESOLVED**: Finding still present or fix is incomplete/incorrect.
   - **REGRESSED**: Fix introduced a new vulnerability.
   - **ACCEPTED**: LOW-severity finding acknowledged with documented rationale.

3. LOW-severity acceptance authority:
   You may ACCEPT LOW findings IF:
   - Real-world risk is mitigated (internal-only, defense-in-depth, narrow attack surface)
   - Fixing would require refactoring outside epic scope
   - Each ACCEPTED LOW must have an explicit rationale

4. Spot-check for new CRITICAL/HIGH issues introduced by the fixes.
   Do NOT re-run the full 7-item security checklist — only check the changed code.

## Output

Append a section to ${findings_file} in this exact format:

\`\`\`markdown
### Verify Cycle ${round}

Verdict: PASS

All CRITICAL/HIGH/MEDIUM findings resolved. N LOW findings accepted.

| Finding | Status | Evidence |
|---------|--------|----------|
| Round N #M: title | RESOLVED | Commit abc fixes X at file:line |
| Round N #M: title | ACCEPTED | Internal-only; mitigated by rate limiting |
\`\`\`

Or if issues remain:

\`\`\`markdown
### Verify Cycle ${round}

Verdict: FAIL

| Finding | Status | Evidence |
|---------|--------|----------|
| Round N #M: title | UNRESOLVED | No code changes found for this finding |
| Round N #M: title | REGRESSED | Fix at file:line introduces new XSS vector |
\`\`\`

## Prohibitions

- Do NOT modify source code (verification only)
- Do NOT add HTML markers to tasks.md (orchestrator responsibility)
- Do NOT commit any files
- Do NOT re-run the full 7-item security checklist
- Do NOT overwrite existing content in ${findings_file} — only APPEND
EOF
}

# ─── Phase: Review ───────────────────────────────────────────────────────────

prompt_review() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

All implementation tasks are complete. Perform a senior code review.

1. List all changed files vs ${MERGE_TARGET}:
   git diff --name-only ${MERGE_TARGET}..HEAD

2. Read EVERY changed file. Check for:
   - Constitution compliance (all principles, all prohibitions)
   - Code style and lint compliance (per CLAUDE.md conventions)
   - Test quality (real assertions, no test theatre, edge cases covered)
   - File size limits and complexity thresholds (per CLAUDE.md)
   - Language-specific best practices (per CLAUDE.md)
   - Error handling (graceful degradation per constitution principles)
   - Observability (structured logging per constitution principles)
   - No hardcoded paths or credentials
   - No print() / console.log debug output (use proper logging)
$(if [[ "${STUB_ENFORCEMENT_LEVEL:-warn}" == "error" ]]; then cat <<'STUB'
   - Integration tests containing t.Skip() are CRITICAL findings. These are stubs that must be implemented, not dismissed. Report each skipped test file as a separate CRITICAL issue.
STUB
fi)
   - Design fidelity (if specs/${short_name}/design-context.md exists):
     * Theme config file exists mapping ALL design tokens to CSS variables or Tailwind theme
     * Design token audit: spot-check 3-5 component/page files for raw hex color values
       that match design tokens. If found, replace with var(--token) or Tailwind class.
       Hex values in theme config files and SVG assets are expected and allowed.
     * All screens from the screen inventory are implemented
     * Component decomposition matches the reusable components catalogue
     * Layout patterns match design specifications (flex, gap, padding, alignment)
     * Icon library matches Implementation Notes
$(if [[ "${HAS_FRONTEND:-false}" == "true" ]]; then cat <<'A11Y'
   - Accessibility (WCAG 2.1 AA):
     * Interactive elements have aria-labels or accessible names
     * Color contrast meets 4.5:1 for text, 3:1 for large text
     * Keyboard navigation works for all interactive flows
     * Images have alt text
     * Form inputs have associated labels
A11Y
fi)
   - Among files changed in this epic (see git diff --name-only above), check for
     exported functions/methods with zero callers outside test files.
     For exported functions with no callers in the diff, use Grep to search the
     FULL project for callers before reporting. Only report as MEDIUM dead code
     if zero callers found project-wide.
     Do NOT report as dead code: init() functions, interface method implementations,
     HTTP/RPC handler functions registered via mux/router, or functions referenced
     in generated code.
     Do NOT report as dead code: stubs or functions tied to deferred tasks (- [-] in tasks.md). However, flag deferred-task code with side effects (unused heavy imports, registered routes, open connections) as MEDIUM.
     Report each confirmed case as:
     MEDIUM: Dead code: file:line — functionName() has no callers in non-test code

3. Write a file \`review-findings.md\` in the spec directory (specs/${short_name}/) with your findings, using these sections:

   ## Spec Compliance (P1)
   [FR coverage findings — which FRs are fully implemented, partially, or missing]

   ## Dead Code
   [Dead code findings with MEDIUM severity, or "None found" if clean]

   ## Issues Found
   [Other review findings, or "None found" if clean]

   Commit this file alongside any fixes you make.

4. Fix any issues found. Commit fixes:
   git add specs/${short_name}/review-findings.md <other specific files>
   git commit -m "fix(${epic_num}): code review — <what was fixed>"

5. Final validation:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_LINT_CMD}"; fi)

6. If any issues remain, fix and commit again.

7. Verify clean working tree:
   git status
   If uncommitted changes remain, commit them with specific file staging:
   git add <specific files touched by review fixes>
   git commit -m "fix(${epic_num}): review cleanup — <brief description>" || true
   If nothing to commit, proceed.
   Verify: git status shows a CLEAN working tree.
   Prefer staging specific files over bulk operations.

8. Report a structured review summary (this will be captured as the review audit trail):

   ## Review Summary
   - **Files reviewed**: <count>
   - **Issues found**: <count>
   - **Issues fixed**: <count> (list each with file:line and one-line description)
   - **Issues dismissed**: <count> (list each with rationale)
   - **Tests**: <pass/fail with count>
   - **Lint**: <pass/fail>
   - **Remaining concerns**: <any items that need human attention>

CRITICAL: After completing ALL steps above (including all fixes, commits, and clean working tree verification), your FINAL action MUST be a text response containing the structured review summary above. Do NOT end your session on a git commit, file edit, or any other tool call. The review summary text is captured as the audit trail — if you end on a tool call, the audit trail will be empty.
EOF
}

prompt_verify_ci_fix() {
    local epic_num="$1" title="$2" repo_root="$3" ci_file="$4" round="$5" max_rounds="$6" warnings_file="${7:-}"
    local git_diff
    git_diff=$(git -C "$repo_root" diff --stat 2>/dev/null || true)

    local ci_section=""
    if [[ -n "$ci_file" ]]; then
        ci_section="Read the CI output from: ${ci_file}"
    fi

    local warnings_section=""
    if [[ -n "$warnings_file" ]]; then
        warnings_section="### Prior Round Warnings\nThe previous fix round was flagged for these issues — do NOT repeat them:\nRead the warnings from: ${warnings_file}"
    fi

    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

## CI Verification Fix — Round ${round}/${max_rounds}

The full CI pipeline failed before merge. Fix these failures with MINIMAL, targeted changes.

### CI Output
${ci_section}

### Working Tree Changes
\`\`\`
${git_diff}
\`\`\`
If generated files appear above, run the project's generate command and commit the result.

$(printf '%b' "${warnings_section}")

### Test File Rules

PERMITTED test file changes:
- Adding stub methods to satisfy interface changes (Go interface compliance)
- Updating import paths for renamed/moved files
- Updating test helper function signatures and fixture data
- Updating mock definitions to match changed interfaces
- Updating build tags (//go:build)
- Updating TestMain/test setup infrastructure
- Adding new test cases for newly added behavior

PROHIBITED test file changes:
- Deleting, commenting out, or skipping test cases
- Weakening assertions (e.g., assertEqual → assertContains, removing error checks)
- Adding try/catch blocks that swallow errors
- Changing expected values to match incorrect output

### Instructions
1. Parse the CI output. Identify the FIRST failing step and root cause.
2. Read relevant source files.
3. Fix ONLY the CI failure — do NOT perform elective refactoring, architectural improvements, style cleanup, or code changes unrelated to the failing CI step. Only make structural changes (package moves, function splits) if strictly necessary to resolve the CI failure.
4. If a test legitimately fails, fix the IMPLEMENTATION, not the test.
5. Common fixes:
   - Lint: unused imports/vars, formatting, type mismatches
   - Test: assertion errors, missing mocks, race conditions
   - Build: missing deps, type errors, import cycles
   - Codegen staleness: run \`make generate\` (or project equivalent) and commit
   - Format: run \`make fmt\` (or project equivalent) and commit
   - Integration test: DB schema mismatch, missing migrations, container config
6. If generated files are dirty in working tree, commit them — they are the correct versions.
7. Commit:
   git add <specific files>
   git commit -m "fix(${epic_num}): resolve CI failures (round ${round})"

### Secret Scanning (Gitleaks)
If secret scanning (gitleaks) reported findings:
- Gitleaks output is JSON: each finding has RuleID, File, StartLine, Secret (redacted), Match, Fingerprint.
- For provider-specific secrets (AWS keys, GitHub tokens, Stripe keys, private keys, etc.):
  - If the value is a KNOWN EXAMPLE/PLACEHOLDER (e.g., AWS-documented
    AKIAIOSFODNN7EXAMPLE, clearly fake values like sk_live_000000000000,
    or values in test fixtures with obvious placeholder patterns):
    Add \`# gitleaks:allow\` inline with a justification comment, e.g.:
    \`AKIAIOSFODNN7EXAMPLE  # gitleaks:allow — AWS documented example key\`
  - If the value appears to be REAL: do NOT allowlist — remove from code,
    flag for rotation, and halt.
- For each non-provider finding, suppress the false positive using this
  preference order:
  1. PREFERRED: Add a regex pattern to .gitleaks.toml [[allowlists]] section
     (path regex for entire directories, or content regex for specific patterns).
  2. GOOD: Add a \`# gitleaks:allow\` inline comment on the flagged line.
  3. LAST RESORT: Add the Fingerprint to .gitleaksignore (one per line, with
     justification comment above).
- After fixing, ensure ALL modified/created config files are staged:
  git add .gitleaks.toml .gitleaksignore <other specific files>

REMEMBER: Your scope is the FAILING CI STEP ONLY. Do not fix unrelated code, improve architecture, address deferred tasks, or make elective refactoring.
EOF
}

# ─── Phase: Crystallize (post-merge context update) ─────────────────────────

prompt_crystallize() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4" diff_file="${5:-}"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

You just merged epic ${epic_num} ("${title}") to ${MERGE_TARGET}. Your job is to update
the project's compressed context files so the next epic starts with current
architectural understanding.

1. Read the merge diff to understand what changed:
   Read the pre-computed diff from: ${diff_file}
   If the file is unavailable or truncated, you can also run:
   git diff ${LAST_MERGE_SHA:-HEAD~2}^..${LAST_MERGE_SHA:-HEAD~2} --stat
   git diff ${LAST_MERGE_SHA:-HEAD~2}^..${LAST_MERGE_SHA:-HEAD~2}

2. Read current context files:
   - CLAUDE.md (look at content between <!-- MANUAL ADDITIONS START --> and <!-- MANUAL ADDITIONS END -->)
   - .specify/memory/architecture.md (if it exists)

3. UPDATE these files to reflect the current codebase state:

   a) CLAUDE.md — edit ONLY the content between the MANUAL ADDITIONS markers:
      - Module map: one line per source module, grouped by layer/purpose
      - Reusable utilities: function signatures that agents MUST use instead of reinventing
      - Pattern rules: conventions agents MUST follow (DB access, error handling, output, testing)
      Keep under 50 lines between the markers. Do NOT modify anything outside the markers.

      For the Reusable utilities section:
      - Document EVERY new utility/helper function added in this epic
      - Include the function signature and a one-line usage example
      - Mark utilities that replace or deprecate previous patterns

      For Pattern rules, include anti-patterns:
      - For each new pattern, add a "DO NOT" counterpart showing the old/wrong way
      - Example: "Use db.Pool for connections — DO NOT create raw pgx connections"
      - Anti-patterns prevent agents from reinventing what already exists

      Pruning stale entries (apply BEFORE adding new content):
      - Remove module-map lines whose source file was DELETED in this epic's diff
      - Remove utility entries for functions no longer in the codebase
      - When two pattern rules share the same "DO NOT" target, consolidate into one rule
      - Do NOT delete any pattern rule outright — only consolidate duplicates
      - Do NOT reduce total MANUAL ADDITIONS content below 15 lines

   b) .specify/memory/architecture.md:
      Create or update 2-4 mermaid diagrams that give a new AI agent immediate
      understanding of this codebase. Choose diagram types appropriate to this
      project's nature. The diagrams must answer:
        - How do modules/components relate? (dependency, layering, ownership)
        - How does data/state flow through the system? (sequences, pipelines, event chains)
        - What are the key entities and their lifecycle states? (state machines, ER diagrams)
        - Where would new functionality be added? (extension points, patterns)
      Keep the file under 120 lines total. Include a brief "Extension Points" prose section.

$(if grep -q 'SOURCE MODULE MAP' "$diff_file" 2>/dev/null; then cat <<'GROUNDING'
IMPORTANT — Ground the module map in actual source code:
The diff file includes a SOURCE MODULE MAP section pre-computed from actual
source files. This is your ONLY source of truth for function signatures.
- ONLY include functions that appear in the SOURCE MODULE MAP section
- If a signature is truncated, read that file at the line number shown
- Group results by file path; omit files with no exported functions
- Use exact names from source — never paraphrase or rename
- If a function appeared in the diff but is NOT in the SOURCE MODULE MAP, it was deleted
GROUNDING
fi)

4. Commit all changes:
   git add CLAUDE.md .specify/memory/architecture.md
   git commit -m "chore(${epic_num}): crystallize context post-merge"
EOF
}

# ─── Phase: Finalize Fix (fix test/lint failures on base branch) ──────────

prompt_finalize_fix() {
    local repo_root="$1" test_file="$2" lint_file="$3"

    local test_section="" lint_section=""
    if [[ -n "$test_file" ]]; then
        test_section="TEST FAILURES:\nRead the test output from: ${test_file}\n"
    fi
    if [[ -n "$lint_file" ]]; then
        lint_section="LINT ISSUES:\nRead the lint output from: ${lint_file}\n"
    fi

    cat <<EOF
IMPORTANT: Read .specify/memory/constitution.md and .specify/memory/architecture.md FIRST.
Internalize all principles, prohibitions, and current architecture. They are non-negotiable.

You are on the ${BASE_BRANCH} branch. ALL epics have been merged. The full test suite or
linter is failing. Your ONLY job is to fix these failures.

Working directory: ${repo_root}

$(printf '%b' "${test_section}${lint_section}")

Instructions:
1. Read the failing test output carefully. Identify root causes.
2. Read the relevant source files and test files.
3. Fix the issues. Prioritize minimal, targeted fixes — do NOT refactor.
4. After fixing, verify:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "   ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "   ${PROJECT_LINT_CMD}"; fi)
5. If issues remain, fix them in a second pass.
6. Commit all fixes:
   git add <specific files>
   git commit -m "fix(finalize): resolve test/lint failures on ${BASE_BRANCH}"
7. Verify clean working tree: git status
EOF
}

# ─── Phase: Finalize Review (cross-epic integration review) ──────────────

prompt_finalize_review() {
    local repo_root="$1"
    cat <<EOF
IMPORTANT: Read .specify/memory/constitution.md and .specify/memory/architecture.md FIRST.
Internalize all principles, prohibitions, and current architecture. They are non-negotiable.

You are on the ${BASE_BRANCH} branch. ALL epics have been merged and tests/lint pass.
Perform a CROSS-EPIC integration review of the complete codebase.

Working directory: ${repo_root}

1. Read CLAUDE.md to understand module map, reusable utilities, and patterns.
2. Read .specify/memory/architecture.md for dependency/flow diagrams.
3. List all source files in the project (check CLAUDE.md for project structure).
4. Read ALL source files. Check for:
   - Cross-module API consistency (function signatures, return types, error handling)
   - Duplicate utility functions that should be consolidated
   - Import cycles or unnecessary coupling between modules
   - Dead code from earlier epics that was superseded by later ones
   - Inconsistent logging patterns across modules
   - Missing or broken module exports
   - Inconsistent data access patterns
   - Constitution compliance across the full codebase
5. Fix any issues found. Commit:
   git add <specific files>
   git commit -m "fix(finalize): cross-epic integration fixes"
6. Final validation:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "   ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "   ${PROJECT_LINT_CMD}"; fi)
7. If tests/lint fail after your changes, fix them immediately.
8. Update .specify/memory/architecture.md with any structural changes.
9. Update CLAUDE.md MANUAL ADDITIONS section if patterns changed.
10. Commit documentation updates:
    git add CLAUDE.md .specify/memory/architecture.md
    git commit -m "docs(finalize): update architecture after integration review"
11. Final report:
    - Issues found and fixed (count)
    - Files modified (count)
    - Any remaining concerns or technical debt
EOF
}

# ─── Phase: Review Fix (resolve code review findings — tier-aware) ────────────

prompt_review_fix() {
    local tier="$1" epic_num="$2" title="$3" repo_root="$4" short_name="$5" review_file="$6"

    local tier_label
    case "$tier" in
        cli)    tier_label="CodeRabbit" ;;
        codex)  tier_label="Codex" ;;
        self)   tier_label="Claude adversarial review" ;;
        *)      tier_label="Code review ($tier)" ;;
    esac

    local review_section=""
    if [[ -n "$review_file" ]]; then
        review_section="${tier_label} REVIEW OUTPUT:\nRead the review output from: ${review_file}"
    fi

    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

${tier_label} has reviewed changes on branch ${short_name} and found potential issues.
Verify each finding against the actual code before acting on it.

$(printf '%b' "${review_section}")

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
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_LINT_CMD}"; fi)
5. Commit all fixes:
   git add <specific files>
   git commit -m "fix(${epic_num}): resolve ${tier_label} review findings"
6. Verify clean working tree: git status
EOF
}

# Backward-compat alias (kept through v0.10.0)
prompt_coderabbit_fix() {
    prompt_review_fix "cli" "$1" "$2" "$3" "$4" "$5"
}

# ─── Phase: Self-Review (adversarial review prompts) ────────────────────────

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

# ─── Phase: Verify Requirements ──────────────────────────────────────────────

prompt_verify_requirements() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4"
    local evidence_file="$5" findings_file="$6" round="$7" max_rounds="$8"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

# Verify Requirements — Round $round/$max_rounds

Read the evidence file at $evidence_file. For each FR-NNN listed:

1. Check the "Code references" — if NONE FOUND, classify as NOT_FOUND
2. If code references exist, read those files and verify the FR's requirements are actually implemented (not just referenced in comments)
3. Classify each FR as:
   - PASS: Fully implemented and tested
   - PARTIAL: Some aspects implemented, others missing
   - NOT_FOUND: No implementation found
   - DEFERRED: Task was marked [-] (intentionally deferred)

Write your findings to $findings_file in this format:
- FR-NNN: PASS|PARTIAL|NOT_FOUND|DEFERRED — brief explanation

If specs/${short_name}/plan.md exists, also read it for implementation approach context. spec.md has the 'what', plan.md has the 'how'.

Be thorough but concise. Check actual code, not just file names.
EOF
}

prompt_requirements_fix() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4"
    local findings_file="$5" failing_frs="$6"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

# Fix Requirement Gaps

The following FRs were found to be NOT_FOUND or PARTIAL during requirements verification:

$failing_frs

Read the findings at $findings_file for details on what is missing.

For each failing FR:
1. Read the spec at specs/$short_name/spec.md to understand the full requirement
2. Read the tasks at specs/$short_name/tasks.md to find which task(s) cover this FR
3. Implement the missing functionality
4. Write tests for the new code
5. Run tests to verify
6. Commit your changes

If specs/${short_name}/plan.md exists, also read it for implementation approach context. spec.md has the 'what', plan.md has the 'how'.

Only fix the FRs listed above. Do not modify unrelated code.
EOF
}

# ─── Phase: Conflict Resolution (rebase conflicts) ──────────────────────────

prompt_conflict_resolve() {
    local epic_num="$1" title="$2" repo_root="$3" conflict_files="$4"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

A rebase onto origin/${MERGE_TARGET} has produced merge conflicts.
Resolve ALL conflicts, preserving the intent of this epic's changes.

CONFLICTING FILES:
${conflict_files}

Instructions:
1. For each conflicting file, read it and understand both sides:
   - OURS (the feature branch changes for epic ${epic_num})
   - THEIRS (the base branch updates)
2. Resolve by:
   - Keeping our feature changes where they don't conflict with base updates
   - Integrating base updates that our code must respect
   - Removing ALL conflict markers (<<<<<<, ======, >>>>>>)
3. After resolving each file:
   git add <resolved file>
4. Do NOT run git rebase --continue — the orchestrator handles that.
5. Verify no conflict markers remain:
   grep -rn '<<<<<<' . --include='*.py' --include='*.ts' --include='*.js' --include='*.sh' --include='*.go' --include='*.rs' || echo "No conflict markers found"
EOF
}
