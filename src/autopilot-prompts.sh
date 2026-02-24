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
EOF
}

# ─── Phase: Clarify ─────────────────────────────────────────────────────────

prompt_clarify() {
    local epic_num="$1" title="$2" epic_file="$3" repo_root="$4" spec_dir="$5"
    local spec_dir_name
    spec_dir_name="$(basename "$spec_dir")"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Read the epic file at ${epic_file} for reference context, then read ${spec_dir}/spec.md.

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
     git commit -m "docs(${epic_num}): clarify complete — zero observations"

If observations WERE found (the skill reported issues, questions, or underspecified areas):
  1. Ensure all fixes and answers have been applied to spec.md
  2. Do NOT add <!-- CLARIFY_COMPLETE -->
  3. Commit fixes:
     git add specs/${spec_dir_name}/
     git commit -m "fix(${epic_num}): resolve clarify observations"

The orchestrator will re-run /speckit.clarify in a fresh context until zero observations
are reported, up to a maximum of 5 rounds.
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
EOF
}

# ─── Phase: Analyze (fix mode) ─────────────────────────────────────────────

prompt_analyze() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4"
    local spec_dir_name
    spec_dir_name="$(basename "$spec_dir")"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Invoke the Skill tool ONCE:
  skill = "speckit.analyze"
  args  = "as a senior developer"

Review the analysis report carefully.

If ZERO issues are found (no CRITICAL, HIGH, MEDIUM, or LOW findings):
  1. Append this exact marker at the END of tasks.md on its own line:
     <!-- ANALYZED -->
  2. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "docs(${epic_num}): spec artifacts ready for implementation"

If ANY issues are found:
  1. Fix ALL issues in the artifacts (spec.md, plan.md, tasks.md) directly
  2. Do NOT add <!-- ANALYZED -->
  3. Commit fixes:
     git add specs/${spec_dir_name}/
     git commit -m "fix(${epic_num}): resolve analysis findings"

The orchestrator will re-run /speckit.analyze in a fresh context until zero issues
are reported, up to a maximum of 5 rounds.
EOF
}

# ─── Phase: Analyze-Verify (fresh-context verification) ───────────────────

prompt_analyze_verify() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4"
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
     git commit -m "fix(${epic_num}): reset analyze state — issues remain"
  The orchestrator will loop back to full analyze in a fresh context.

If zero issues:
  1. Replace <!-- FIXES APPLIED --> with <!-- ANALYZED --> in tasks.md
  2. Commit:
     git add specs/${spec_dir_name}/
     git commit -m "docs(${epic_num}): spec artifacts ready for implementation"
EOF
}

# ─── Phase: Design Read (extract design context from .pen file) ──────────

prompt_design_read() {
    local epic_num="$1" title="$2" repo_root="$3" spec_dir="$4" pen_file="$5"
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

Read the design file at: ${pen_file}
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
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

Read ALL design artifacts in ${spec_dir}/ to understand the full scope.
If ${spec_dir}/design-context.md exists, read it. It is the authoritative visual specification:
- Match design tokens EXACTLY — map to CSS custom properties or Tailwind config
- Implement ALL screens listed in the screen inventory
- Use the reusable components catalogue as your component decomposition guide
- Follow the layout patterns precisely (flex directions, gaps, padding, alignment)
- Use the specified icon library (check Implementation Notes section)
Also read CLAUDE.md for project conventions, reusable utilities, and patterns.

When launching Task subagents for parallel [P] tasks, include this instruction
in each subagent prompt:
  "Before writing code, read .specify/memory/architecture.md for module
  dependencies and CLAUDE.md for reusable utilities and patterns.
  If specs/{name}/design-context.md exists, also read it for design token
  values, component structure, layout specifications, and the Theme Integration
  rules. Reference design tokens via CSS variables or Tailwind classes —
  never hardcode hex color values in component or page files."

Then invoke the Skill tool:
  skill = "speckit.implement"
  args  = "all tasks using subagents for parallel [P] tasks"

The skill will:
- Read tasks.md and identify phases, dependencies, and [P] markers
- Dispatch independent [P] tasks as parallel subagents via the Task tool
- Execute sequential tasks in dependency order
- Follow strict TDD for each task (test first, implement, verify)
- Mark each task [x] in tasks.md after completion
- Commit after each task or logical group

After the skill completes, verify:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "  cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "  cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_LINT_CMD}"; fi)
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
   - Integration tests containing t.Skip() are CRITICAL findings. These are stubs that must be implemented, not dismissed. Report each skipped test file as a separate CRITICAL issue.
   - Design fidelity (if specs/${short_name}/design-context.md exists):
     * Theme config file exists mapping ALL design tokens to CSS variables or Tailwind theme
     * Design token audit: spot-check 3-5 component/page files for raw hex color values
       that match design tokens. If found, replace with var(--token) or Tailwind class.
       Hex values in theme config files and SVG assets are expected and allowed.
     * All screens from the screen inventory are implemented
     * Component decomposition matches the reusable components catalogue
     * Layout patterns match design specifications (flex, gap, padding, alignment)
     * Icon library matches Implementation Notes

3. Fix any issues found. Commit fixes:
   git add <specific files>
   git commit -m "fix(${epic_num}): code review — <what was fixed>"

4. Final validation:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_LINT_CMD}"; fi)

5. If any issues remain, fix and commit again.

6. Commit ALL remaining changes (ensure clean working tree for merge):
   git status
   git add <all modified/new files relevant to this epic>
   git commit -m "feat(${epic_num}): final review changes" || echo "Nothing to commit"
   Verify: git status shows a CLEAN working tree with no uncommitted changes.

7. Report a structured review summary (this will be captured as the review audit trail):

   ## Review Summary
   - **Files reviewed**: <count>
   - **Issues found**: <count>
   - **Issues fixed**: <count> (list each with file:line and one-line description)
   - **Issues dismissed**: <count> (list each with rationale)
   - **Tests**: <pass/fail with count>
   - **Lint**: <pass/fail>
   - **Remaining concerns**: <any items that need human attention>
EOF
}

# ─── Phase: Crystallize (post-merge context update) ─────────────────────────

prompt_crystallize() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

You just merged epic ${epic_num} ("${title}") to ${MERGE_TARGET}. Your job is to update
the project's compressed context files so the next epic starts with current
architectural understanding.

1. Read the merge diff to understand what changed:
   git diff HEAD~1..HEAD --stat
   git diff HEAD~1..HEAD

2. Read current context files:
   - CLAUDE.md (look at content between <!-- MANUAL ADDITIONS START --> and <!-- MANUAL ADDITIONS END -->)
   - .specify/memory/architecture.md (if it exists)

3. UPDATE these files to reflect the current codebase state:

   a) CLAUDE.md — edit ONLY the content between the MANUAL ADDITIONS markers:
      - Module map: one line per source module, grouped by layer/purpose
      - Reusable utilities: function signatures that agents MUST use instead of reinventing
      - Pattern rules: conventions agents MUST follow (DB access, error handling, output, testing)
      Keep under 50 lines between the markers. Do NOT modify anything outside the markers.

   b) .specify/memory/architecture.md:
      Create or update 2-4 mermaid diagrams that give a new AI agent immediate
      understanding of this codebase. Choose diagram types appropriate to this
      project's nature. The diagrams must answer:
        - How do modules/components relate? (dependency, layering, ownership)
        - How does data/state flow through the system? (sequences, pipelines, event chains)
        - What are the key entities and their lifecycle states? (state machines, ER diagrams)
        - Where would new functionality be added? (extension points, patterns)
      Keep the file under 120 lines total. Include a brief "Extension Points" prose section.

4. Commit all changes:
   git add CLAUDE.md .specify/memory/architecture.md
   git commit -m "chore(${epic_num}): crystallize context post-merge"
EOF
}

# ─── Phase: Finalize Fix (fix test/lint failures on base branch) ──────────

prompt_finalize_fix() {
    local repo_root="$1" test_output="$2" lint_output="$3"
    cat <<EOF
IMPORTANT: Read .specify/memory/constitution.md and .specify/memory/architecture.md FIRST.
Internalize all principles, prohibitions, and current architecture. They are non-negotiable.

You are on the ${BASE_BRANCH} branch. ALL epics have been merged. The full test suite or
linter is failing. Your ONLY job is to fix these failures.

Working directory: ${repo_root}

TEST FAILURES:
\`\`\`
${test_output}
\`\`\`

LINT ISSUES:
\`\`\`
${lint_output}
\`\`\`

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

# ─── Phase: CodeRabbit Fix (resolve CodeRabbit review findings) ─────────────

prompt_coderabbit_fix() {
    local epic_num="$1" title="$2" repo_root="$3" short_name="$4" review_output="$5"
    cat <<EOF
$(_preamble "$epic_num" "$title" "$repo_root")

CodeRabbit has reviewed changes on branch ${short_name} and found issues.
Fix ALL issues identified below, then verify.

CODERABBIT REVIEW OUTPUT:
\`\`\`
${review_output}
\`\`\`

Instructions:
1. Read each issue carefully — understand the file and line referenced.
2. Read the relevant source files.
3. Fix all CRITICAL and HIGH severity issues — these are mandatory.
   For MEDIUM issues: fix only if straightforward (< 5 lines changed).
   For LOW issues: do NOT fix them. Log them as accepted tech debt in a brief code comment if appropriate.
   Focus your effort on the issues that matter most.
4. After fixing, verify:
$(if [[ -n "$PROJECT_TEST_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_TEST_CMD}"; fi)
$(if [[ -n "$PROJECT_LINT_CMD" ]]; then echo "   cd ${repo_root}/${PROJECT_WORK_DIR} && ${PROJECT_LINT_CMD}"; fi)
5. Commit all fixes:
   git add <specific files>
   git commit -m "fix(${epic_num}): resolve CodeRabbit review findings"
6. Verify clean working tree: git status
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
