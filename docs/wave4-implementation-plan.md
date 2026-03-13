# Wave 4 Implementation Plan — Secret Scanning & Branch Scoping

**Version:** 0.11.0 (target)
**Predecessor:** Wave 3 (v0.10.0) — all 22 items shipped
**Date:** 2026-03-13
**Status:** DRAFT — awaiting approval

---

## Executive Summary

Two gaps remain from the always-forward analysis. Wave 4 closes both:

1. **P6: Gitleaks Secret Scanning** — deterministic secret detection alongside existing LLM-based security review (~105 lines net new)
2. **P3: Branch-Scoped Skip Detection** — replace full-repo `grep -rn` / `find` with branch-diff-filtered scanning (~20 lines)

Both are opt-in, non-breaking, and follow established patterns in the codebase.

---

## Motivation

### Why Gitleaks?

The existing `security-review` phase (LLM-only) has a single prose checklist item for secrets (`autopilot-prompts.sh:522`: "No hardcoded credentials, API keys, or tokens"). This is:

- **Non-deterministic** — LLMs miss base64-encoded, high-entropy, and provider-prefixed strings
- **Non-reproducible** — different runs may catch different secrets
- **Insufficient** — AI-generated code has ~40% higher secret leak rate (Truffle Security); GitHub reported 39M leaked secrets in 2024 (+67% YoY)

Gitleaks provides regex + entropy scanning with 100+ built-in provider rules. Combined with the LLM review, this creates defence in depth.

### Why Branch-Scoping?

Skip detection (`autopilot-verify.sh:42-86`) currently scans the entire repo via `find` and `grep -rn`. Pre-existing skips from before the epic started trigger false positives. The always-forward analysis (line 476-480) identifies branch-scoping as an "always-forward enabler": narrower scope = fewer false halts.

---

## Architecture

```mermaid
graph TD
    subgraph "verify-ci pipeline (autopilot-verify.sh)"
        A[Step 0: Secret Scan] -->|HALT on Tier 1| STOP((HALT))
        A -->|fix-loop on Tier 2| B[Step 1: Frontend Deps]
        B --> C[Step 2: Format Check]
        C --> D[Step 3: Codegen Staleness]
        D --> E[Step 4: Lint]
        E --> F[Step 5: Tests + branch-scoped skip detection]
        F --> G[Step 6: Integration]
        G --> H[Step 7: Build]
        H --> I[Step 8: E2E]
    end

    subgraph "Gitleaks Two-Tier Classification"
        J[gitleaks dir] --> K{Provider pattern?}
        K -->|Yes: AKIA, ghp_, sk_live| L[Tier 1: HALT]
        K -->|No: generic/entropy| M[Tier 2: Fix Loop]
        M --> N[Claude adds to .gitleaks.toml allowlist / inline gitleaks:allow / .gitleaksignore]
        N --> O[Re-scan]
    end
```

---

## Item 1: Gitleaks Secret Scanning

### 1.1 Design

**Two-tier model** (from `always-forward-analysis.md:157-162`):

| Tier | Pattern Type | Examples | Behaviour |
|------|-------------|----------|-----------|
| **1** | Provider-specific (known prefix) | `AKIA*`, `ghp_*`, `sk_live_*`, `-----BEGIN.*PRIVATE KEY-----` | **Immediate HALT** — rotation required, removal from HEAD is security theatre |
| **2** | Generic/entropy matches | `generic-api-key`, high-entropy strings | **Fix loop** — Claude justifies to `.gitleaksignore` or removes; re-scan |

**Rationale for two tiers:** Provider-prefixed secrets (AWS AKIA, GitHub ghp_, Stripe sk_live) are confirmed real by their prefix alone — no human judgment needed. Generic matches have high false-positive rates and benefit from AI triage.

**False-positive prevention:** Tier 2 findings never halt the pipeline. They enter the existing CI fix loop where Claude either removes the secret or justifies it to `.gitleaksignore`. Only Tier 1 rules (which have unique provider prefixes and zero false-positive risk) can halt. Combined with branch-scoping and auto-generated `.gitleaks.toml` allowlists, this creates a three-layer false-positive defence.

### 1.2 Tier 1 Rule IDs (HALT list)

26 gitleaks built-in `RuleID` values trigger immediate halt. Selection criterion: **unique provider prefix = zero/near-zero false positives**. See [Resolved Q5](#q5-tier-1-list-completeness--resolved-expand-from-10-to-26-rules) for full rationale.

```
# Cloud providers
aws-access-token                       # AKIA/ASIA/ABIA/ACCA prefix
gcp-service-account                    # GCP service account JSON structure (currently inactive upstream — removed from gitleaks defaults; covered by private-key; PR #1930 pending)
gcp-api-key                            # AIza prefix
digitalocean-pat                       # dop_v1_ prefix
cloudflare-origin-ca-key               # v1.0- prefix

# Cryptographic
private-key                            # -----BEGIN.*PRIVATE KEY-----
age-secret-key                         # AGE-SECRET-KEY-1

# Source control
github-pat                             # ghp_ prefix
github-fine-grained-pat                # github_pat_ prefix
github-app-token                       # ghu_/ghs_ prefix
github-oauth                           # gho_ prefix
github-refresh-token                   # ghr_ prefix
gitlab-pat                             # glpat- prefix

# CI/CD
gitlab-ptt                             # glptt- prefix
gitlab-runner-authentication-token     # glrt- prefix

# Payments
stripe-access-token                    # sk_live_/rk_live_/sk_test_/rk_test_

# Communication
slack-bot-token                        # xoxb- prefix
slack-user-token                       # xoxp- prefix
slack-webhook-url                      # hooks.slack.com

# AI/ML
openai-api-key                         # sk-proj- prefix
anthropic-api-key                      # sk-ant-api03- prefix
anthropic-admin-api-key                # sk-ant-admin01- prefix

# Email
sendgrid-api-token                     # SG. prefix

# Supply chain
npm-access-token                       # npm_ prefix
pypi-upload-token                      # pypi-AgEIcHlwaS5vcmc prefix

# E-commerce
shopify-access-token                   # shpat_ prefix
```

All other RuleIDs are Tier 2 (fix-loop).

Configurable via `PROJECT_SECRET_TIER1_RULES` in `project.env` (pipe-separated override).

### 1.3 Configuration Variables

Added to `project.env` by `autopilot-detect-project.sh`:

```bash
# Secret scanning (opt-in; requires gitleaks in PATH)
PROJECT_SECRET_SCAN_CMD=""           # Auto-set to "gitleaks" if detected
PROJECT_SECRET_TIER1_RULES=""        # Override Tier 1 RuleIDs (pipe-separated)
PROJECT_SECRET_SCAN_MODE="branch"    # "branch" (default) or "full"
```

### 1.4 Auto-Detection (`autopilot-detect-project.sh`)

**Prerequisite refactor:** `autopilot-detect-project.sh` is currently 499 lines (at the 500-line limit). Before adding gitleaks detection, extract all `detect_*()` functions and `_ensure_gitignore_logs()` into a new `autopilot-detect-tools.sh` (~160 lines). This follows the established codebase pattern (e.g., `autopilot-verify.sh` extracted from `autopilot-lib.sh`). Result: `autopilot-detect-project.sh` drops to ~340 lines; gitleaks detection is added to the new tools file.

**install.sh update:** `install.sh:116` uses explicit file listing (no glob pattern); `autopilot-detect-tools.sh` must be added to the script copy loop.

Add gitleaks detection to `autopilot-detect-tools.sh` (~25 lines total):

```bash
# Secret scanning
if command -v gitleaks >/dev/null 2>&1; then
    PROJECT_SECRET_SCAN_CMD="gitleaks"
    log INFO "Detected gitleaks — secret scanning enabled"
    log INFO "Tip: Add gitleaks pre-commit hook for local protection: https://github.com/gitleaks/gitleaks#pre-commit"
fi
```

**`.gitleaks.toml` generation:** When gitleaks is detected AND no `.gitleaks.toml` exists at repo root, generate a starter config that extends defaults with project-appropriate allowlists:

```toml
# Auto-generated by speckit-autopilot — extends gitleaks defaults
[extend]
useDefault = true

[[allowlists]]
  description = "Allowlist for known safe patterns"
  paths = [
    '''\.env\..*\.example$''',
    '''\.env\.example$''',
    '''fixtures/''',
    '''testdata/''',
  ]
  regexTarget = "line"
  regexes = [
    '''CHANGE_ME''',
    '''placeholder''',
    '''example\.com''',
    '''YOUR_.*_HERE''',
    '''AKIAIOSFODNN7EXAMPLE''',
    '''wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY''',
    '''sk_live_0{6,}''',
    '''sk_test_0{6,}''',
    '''ghp_0{6,}''',
  ]
```

> **`[[allowlists]]` syntax note:** `[allowlist]` was deprecated in gitleaks v8.x, replaced by `[[allowlists]]` (TOML array of tables). The old syntax still works via a backward-compat shim but source code TODOs indicate removal in v9.x (no public timeline announced). Using both syntaxes in the same file errors out. The `targetRules` field (new in v8.25.0) has a known bug ([#1919](https://github.com/gitleaks/gitleaks/issues/1919)) — not used here but worth noting for future customization.

This is the primary false-positive prevention mechanism. Repos that already have `.gitleaks.toml` are left untouched. The `useDefault = true` directive ensures all 264+ built-in rules remain active — the custom config only adds allowlists, never replaces detection rules.

Inserted in `autopilot-detect-tools.sh` alongside the other `detect_*()` functions. Called from `autopilot-detect-project.sh` after the CodeRabbit/Codex detection block.

### 1.5 Scan Function (`autopilot-verify.sh`)

New function `verify_secrets()` (~60 lines):

```
verify_secrets(repo_root) -> 0 (pass) | 1 (Tier 1 found)
```

**Algorithm:**

1. Skip if `PROJECT_SECRET_SCAN_CMD` is empty (not installed / not opted in)
2. Set global: `LAST_SECRET_SCAN_TIER=0`
3. Determine scan scope and run gitleaks:
   - **IMPORTANT:** `gitleaks dir` uses a **positional argument** for the path, NOT `--source` (which only exists on the deprecated `detect` command and causes hard failure exit code 126 on `dir`). Must run from repo root with `.` as the path to ensure fingerprints use repo-relative paths (upstream issue [#1287](https://github.com/gitleaks/gitleaks/issues/1287) — absolute paths in fingerprints break `.gitleaksignore` portability across environments).
   - `branch` mode (default): First get changed files via `git diff --name-only --diff-filter=ACMRT "${MERGE_TARGET}..HEAD"`, then run `(cd "$repo_root" && run_with_timeout 60 gitleaks dir --report-format json --report-path "$report" --redact --exit-code 2 --max-decode-depth=1 .)`. Post-filter the JSON report to only include findings in branch-changed files.
   - `full` mode: `(cd "$repo_root" && run_with_timeout 60 gitleaks dir --report-format json --report-path "$report" --redact --exit-code 2 --max-decode-depth=1 .)`
   - Using `gitleaks dir` scans current file state (not git history). This is correct for the CI fix-loop: Claude can only fix secrets that exist in current files. Secrets added then removed in intermediate commits are not a deployment risk (squash merges collapse history). `.gitleaks.toml` at repo root is auto-discovered.
   - `--max-decode-depth=1` catches single-layer base64/hex-encoded secrets without the OOM risk of the code default (5; README incorrectly documents 0 — see [gitleaks #2019](https://github.com/gitleaks/gitleaks/issues/2019)).
   - Wrapped in `run_with_timeout 60` (existing infrastructure in `autopilot-lib.sh`) as a safety net against hangs.
3a. Check report file exists: if `$report` does not exist, log WARN and treat as clean (graceful degradation for gitleaks errors or v8.22.0 edge case where no report file was generated on clean scans).
4. Parse JSON report with `jq` (already available as a dependency for stream processing). Note: `StartLine` is the line number integer; `Line` is the full source line text.
5. Classify each finding:
   - Extract `RuleID` from each finding
   - Check against Tier 1 list
   - If ANY Tier 1 match: set `LAST_SECRET_SCAN_TIER=1`, log CRITICAL, return 1
   - If only Tier 2 matches: set `LAST_SECRET_SCAN_TIER=2`, log WARN with count, return 0
   - If no findings: `LAST_SECRET_SCAN_TIER=0`, return 0
   - Exit code 0 = no findings, exit code 2 = findings found (parse report), exit code 1 = error (graceful degradation). The `--exit-code 2` flag disambiguates findings from errors.
   - If gitleaks exit code 1 (error), missing report file, or timeout: log WARN, set `LAST_SECRET_SCAN_TIER=0`, return 0 (graceful degradation — broken tool must not block pipeline)
6. Clean up temp report file

### 1.6 Integration Point: verify_ci() Pipeline

Insert as **Step 0** (before format check) in `verify_ci()` at `autopilot-verify.sh:184`:

```bash
# Step 0: Secret scanning (before any other checks — Path B only)
if [[ -n "${PROJECT_SECRET_SCAN_CMD:-}" ]]; then
    if ! verify_secrets "$repo_root"; then
        if [[ "${LAST_SECRET_SCAN_TIER:-0}" -eq 1 ]]; then
            LAST_CI_OUTPUT="=== STEP: Secret Scan === HALT (Tier 1 provider secret detected)"
        else
            LAST_CI_OUTPUT="=== STEP: Secret Scan === FAIL (Tier 2 findings — fix loop)"
        fi
        rm -f "$tmpfile"; return 1
    fi
fi
```

~10 lines in `verify_ci()`, inserted at the top of Path B (line 184). Not inserted before Path A — repos with `PROJECT_CI_CMD` are responsible for their own secret scanning.

### 1.7 Tier 2 Fix Loop Integration

When `verify_secrets()` returns 0 but logs Tier 2 warnings, the existing `_run_verify_ci_gate()` fix loop handles it:

1. CI fails (Tier 2 findings in output)
2. `prompt_verify_ci_fix()` receives the gitleaks output in `$LAST_CI_OUTPUT`
3. Claude either:
   - Removes the secret from code, OR
   - Adds a `.gitleaksignore` entry with justification comment
4. Re-scan on next round

**New prompt injection** in `prompt_verify_ci_fix()` (~10 lines):

```
If secret scanning (gitleaks) reported findings:
- Gitleaks output is JSON: each finding has RuleID, File, StartLine, Secret (redacted), Match, Fingerprint.
- For provider-specific secrets (AWS keys, GitHub tokens, Stripe keys,
  private keys, etc.):
  - If the value is a KNOWN EXAMPLE/PLACEHOLDER (e.g., AWS-documented
    AKIAIOSFODNN7EXAMPLE, clearly fake values like sk_live_000000000000,
    or values in test fixtures with obvious placeholder patterns):
    Add `# gitleaks:allow` inline with a justification comment, e.g.:
    `AKIAIOSFODNN7EXAMPLE  # gitleaks:allow — AWS documented example key`
  - If the value appears to be REAL: do NOT allowlist — remove from code,
    flag for rotation, and halt.
- For each non-provider finding, suppress the false positive using this
  preference order:
  1. PREFERRED: Add a regex pattern to .gitleaks.toml [[allowlists]] section
     (path regex for entire directories, or content regex for specific patterns).
     Example: paths = ['''fixtures/'''] or regexes = ['''CHANGE_ME''']
  2. GOOD: Add a # gitleaks:allow inline comment on the flagged line in the
     source file (useful for individual one-off suppressions you control).
  3. LAST RESORT: Add the Fingerprint to .gitleaksignore (one per line, with a
     justification comment above). Note: .gitleaksignore fingerprints have a
     known portability issue (gitleaks #1287) — absolute paths break across
     environments. Only works reliably when gitleaks is invoked from repo root
     with . path (which autopilot always does).
- If a secret is in a .env.example file with a placeholder value like CHANGE_ME,
  prefer adding a .gitleaks.toml path allowlist for the example file pattern.
- After fixing, ensure ALL modified/created config files are staged:
  git add .gitleaks.toml .gitleaksignore <other specific files>
  This follows the established codebase pattern where prompts explicitly name
  new files in git add instructions (cf. review-findings.md, design-context.md).
```

### 1.8 Three-Tier Suppression Strategy

Gitleaks false positives are suppressed via three mechanisms, in preference order:

| Tier | Mechanism | Scope | Portability | When to Use |
|------|-----------|-------|-------------|-------------|
| **1 (preferred)** | `.gitleaks.toml` `[[allowlists]]` section | Regex-based: path patterns, content patterns | Fully portable — regex, no environment dependency | Directories (fixtures/, testdata/), recurring patterns (CHANGE_ME, example.com) |
| **2 (good)** | `# gitleaks:allow` inline comment | Single line in source file | Fully portable — travels with the code | One-off suppressions in files you control |
| **3 (last resort)** | `.gitleaksignore` fingerprints | Single finding (file:ruleID:line) | **Caveat:** absolute paths break across environments (upstream issue [#1287](https://github.com/gitleaks/gitleaks/issues/1287)); mitigated by always running `gitleaks dir .` from repo root so fingerprints use relative paths | When `.gitleaks.toml` regex is too broad and inline comment is not possible |

**Implementation details:**
- `.gitleaks.toml` is auto-generated during project detection (Section 1.4) with starter allowlists
- `.gitleaksignore` is auto-created at repo root if Claude adds fingerprint entries
- Each `.gitleaksignore` entry must have a justification comment above it
- All suppression files are committed alongside the fix

### 1.9 Fake/Placeholder Key Handling

Tier 1 rules use provider prefixes to achieve zero false-positive classification. However, **documented example keys** and **obvious placeholders** share those prefixes (e.g., AWS's `AKIAIOSFODNN7EXAMPLE`). Without special handling, these cause un-resolvable HALTs.

**Two-layer defence against fake-key false positives:**

1. **Gitleaks-level** (before classification): The auto-generated `.gitleaks.toml` (Section 1.4) includes regexes for well-known documented example keys (AWS, Stripe, GitHub). Gitleaks itself suppresses these — they never reach tier classification.

2. **Prompt-level** (during fix loop): The fix prompt (Section 1.7) instructs Claude to distinguish fake vs real provider secrets. Obviously fake values get `# gitleaks:allow` inline; real values trigger removal and rotation.

**Why not blanket-allowlist `tests/`?** Real secrets frequently end up in test files (copy-pasted for quick validation, forgotten). Allowlisting entire directories would permanently blind the scanner to a common leak vector. The prompt-based approach preserves detection while adding judgment.

### 1.10 Tier 1 HALT Behaviour

When a Tier 1 secret is found:

1. `verify_secrets()` sets `LAST_SECRET_SCAN_TIER=1` and returns 1
2. `verify_ci()` returns 1 (Step 0 failed)
3. `_run_verify_ci_gate()` enters fix loop — but Tier 1 secrets re-trigger every round
4. After `max_rounds`, gate checks `LAST_SECRET_SCAN_TIER` before force-skipping

**Special handling in `_run_verify_ci_gate()`** (~5 lines):

```bash
# Tier 1 secrets override force-skip — always halt
if [[ "${LAST_SECRET_SCAN_TIER:-0}" -eq 1 ]]; then
    log ERROR "Tier 1 provider secret detected — cannot force-skip. Rotate the secret and remove from git history."
    return 1
fi
```

This replaces the fragile string-matching approach (`*"Tier 1 provider secret"*` on `LAST_CI_OUTPUT`) with a dedicated global variable. The global variable pattern is consistent with existing codebase conventions (`CI_FIX_TEST_WARN`, `LAST_TEST_OUTPUT`) and immune to the 8000-char truncation in `_capture_ci_output()`.

`LAST_SECRET_SCAN_TIER` values: `0` = clean, `1` = Tier 1 (provider secret, must halt), `2` = Tier 2 (generic/entropy, fix loop).

### 1.11 Test Plan

| Test | Validates |
|------|-----------|
| `test-secret-scan-tier1.sh` | Tier 1 RuleID detection → immediate HALT, no force-skip possible |
| `test-secret-scan-tier2.sh` | Tier 2 findings → fix loop entry, .gitleaksignore handling |
| `test-secret-scan-skip.sh` | No gitleaks installed → graceful skip, no error |
| `test-secret-scan-branch.sh` | Branch-mode scans only changed files |
| `test-secret-scan-config.sh` | Custom Tier 1 rules via `PROJECT_SECRET_TIER1_RULES` |
| `test-detect-project-gitleaks.sh` | Auto-detection of gitleaks in `autopilot-detect-tools.sh` |

### 1.12 Files Modified

| File | Change | Lines |
|------|--------|-------|
| `src/autopilot-detect-tools.sh` | Extract `detect_*()` functions from detect-project + add `detect_gitleaks()` | ~170 |
| `src/autopilot-detect-project.sh` | Source detect-tools.sh, add gitleaks env vars to project.env template | ~5 |
| `src/autopilot-verify.sh` | Add `verify_secrets()` function | ~55 |
| `src/autopilot-verify.sh` | Insert Step 0 in `verify_ci()` | ~10 |
| `src/autopilot-gates.sh` | Tier 1 force-skip override in `_run_verify_ci_gate()` | ~5 |
| `src/autopilot-prompts.sh` | Add gitleaks context to `prompt_verify_ci_fix()` | ~10 |
| `install.sh` | Add `autopilot-detect-tools.sh` to script copy list (line 116) | ~1 |
| `tests/test-detect-project.sh` | Update sed source path from `autopilot-detect-project.sh` to `autopilot-detect-tools.sh` (line 35) | ~1 |
| `tests/test-detect-monorepo.sh` | Update sed source path from `autopilot-detect-project.sh` to `autopilot-detect-tools.sh` (line 37) | ~1 |
| **Total** | | **~258** |

---

## Item 2: Branch-Scoped Skip Detection

### 2.1 Current Problem

`verify_tests()` in `autopilot-verify.sh:42-86` uses full-repo scanning:

```bash
# Go: find "$repo_root" -name '*_test.go' ...
# Python: grep -rnE '@pytest.mark.skip' "$repo_root" ...
# Node: grep -rnE '...\.skip\s*\(' "$repo_root" ...
# Rust: grep -rnE '#\[ignore\]' "$repo_root" ...
```

This detects skips in files untouched by the current epic, generating false positives from legacy code.

### 2.2 Solution

Filter scan targets to branch-changed files only, with graceful fallback:

```bash
# Guard: only attempt branch-scoping inside a git repo
local changed_files=""
if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    changed_files=$(git -C "$repo_root" diff --name-only --diff-filter=ACMRT \
        "${MERGE_TARGET:-main}..HEAD" 2>/dev/null || true)
fi

# If no changed files (non-git repo, branch not found, or git fails), fall back to full scan
if [[ -z "$changed_files" ]]; then
    # ... existing full-repo scan (unchanged)
fi
```

Key details:
- **`MERGE_TARGET`** (not `BASE_BRANCH`): matches the established convention in `autopilot-prompts.sh:609`, `autopilot-merge.sh:78`
- **`--diff-filter=ACMRT`**: excludes deleted files (D) — ensures every returned path exists on disk. Includes Added, Copied, Modified, Renamed, Type-changed.
- **`git rev-parse --is-inside-work-tree`**: guards against non-git directories (test fixtures use bare `mktemp` dirs without `git init`). This preserves all existing test behavior without requiring test fixture changes.
- **Fallback to full-repo scan**: if git check fails, local branch doesn't exist, or diff returns empty — behaviour is identical to current v0.10.0

Then filter each language's scan to only search within `$changed_files`:

- **Go:** Filter `find` results through `grep -F` against changed files list
- **Python:** Pass changed `test_*.py` / `*_test.py` files directly to `grep`
- **Node:** Pass changed `*.test.ts` / `*.spec.js` etc files directly to `grep`
- **Rust:** Pass changed `*.rs` files directly to `grep`

### 2.3 Algorithm

```
1. Guard: git rev-parse --is-inside-work-tree (if false → full-repo scan)
2. changed_files = git diff --name-only --diff-filter=ACMRT ${MERGE_TARGET}..HEAD
3. If empty or failed → fall back to full-repo scan (defensive)
4. Filter changed_files by language-specific test file patterns
5. If filtered list empty → no test files changed → skip detection passes
6. Run language-specific skip pattern grep ONLY on filtered files
7. Apply speckit:allow-skip filter (unchanged)
8. Apply STUB_ENFORCEMENT_LEVEL logic (unchanged)
```

### 2.4 Reference Implementation

The pattern already exists in the codebase (majority uses bare branch name, no `origin/` prefix):

- `autopilot-prompts.sh:609`: `git diff --name-only ${MERGE_TARGET}..HEAD` (review phase — canonical pattern)
- `autopilot-merge.sh:78`: `git diff --name-only ${MERGE_TARGET}..HEAD` (merge phase)
- `autopilot-verify.sh:319`: `git diff --name-only "$head_before"..HEAD` (test modification detection)
- `autopilot.sh:499`: `git diff --name-only ${MERGE_TARGET}..HEAD` (main loop)
- `autopilot-prompts.sh:981`: `git diff --name-only origin/${merge_target}..HEAD` (security review prompt — exception; runs in different context)

`detect_merge_target()` returns a bare branch name (e.g., "staging"), not "origin/staging". Since `git fetch` runs during the merge phase (after verify-ci where skip detection runs), `origin/` refs may be stale. The bare `${MERGE_TARGET}..HEAD` form is correct here.

### 2.5 Edge Cases

| Scenario | Behaviour |
|----------|-----------|
| First run (local MERGE_TARGET branch may not exist) | `git diff` fails → fallback to full-repo scan |
| Detached HEAD | MERGE_TARGET is still a branch name; `git diff` works if branch exists locally |
| No test files changed | Skip detection auto-passes (no files to scan) |
| `--strict` mode | Branch-scoping still applies — strict controls enforcement level, not scan scope |
| Epic touches 0 test files but adds skips to existing tests | Caught: `git diff --name-only` includes modified files |

### 2.6 Test Plan

| Test | Validates |
|------|-----------|
| `test-branch-scoped-skip.sh` | Only detects skips in branch-changed files |
| `test-branch-scoped-fallback.sh` | Falls back to full-repo when git diff fails |
| Update `test-multi-lang-skip.sh` | Existing tests still pass with scoped scanning |

### 2.7 Files Modified

| File | Change | Lines |
|------|--------|-------|
| `src/autopilot-verify.sh` | Refactor `verify_tests()` skip detection to use branch-scoped file list | ~20 |
| **Total** | | **~20** |

---

## Implementation Order

```mermaid
graph LR
    A0["Step 0: Extract autopilot-detect-tools.sh<br/>(prerequisite refactor)"] --> A
    A["Step 1: Branch-scoped skip detection<br/>(Item 2, ~20 lines)"] --> B["Step 2: Gitleaks auto-detection<br/>(Item 1.4, ~10 lines)"]
    B --> C["Step 3: verify_secrets() function<br/>(Item 1.5, ~60 lines)"]
    C --> D["Step 4: verify_ci() integration<br/>(Item 1.6, ~8 lines)"]
    D --> E["Step 5: Tier 1 override in gates<br/>(Item 1.9, ~5 lines)"]
    E --> F["Step 6: Prompt injection<br/>(Item 1.7, ~10 lines)"]
```

**Step 1** ships independently — zero dependency on gitleaks. Can be merged first as a standalone quality improvement.

**Steps 2-6** are the gitleaks implementation, ordered by dependency: detection → function → integration → gate override → prompt.

### Batch Strategy

| Batch | Items | Commit |
|-------|-------|--------|
| **Batch 0** | Prerequisite: extract autopilot-detect-tools.sh from autopilot-detect-project.sh + update install.sh copy list + update test sed paths + add extraction test with install.sh assertion | `refactor(wave4): extract autopilot-detect-tools.sh` |
| **Batch 1** | Item 2 (branch-scoped skip detection) | `feat(wave4): branch-scoped skip detection` |
| **Batch 2** | Items 1.4–1.9 (gitleaks full implementation: detection → scan function → CI integration → gate override → prompt) | `feat(wave4): gitleaks two-tier secret scanning` |
| **Batch 3** | All tests | `test(wave4): secret scanning + branch-scoped skip tests` |
| **Batch 4** | Version bump to 0.11.0 | `feat(wave4): v0.11.0` |

---

## Dependency: jq

`verify_secrets()` uses `jq` to parse gitleaks JSON output. `jq` is already an implicit dependency of the stream processor (`autopilot-stream.sh`). No new dependency introduced.

If `jq` is unavailable, fall back to `grep`/`awk` parsing of the JSON report (less robust but functional).

## Dependency: gitleaks

Gitleaks is **opt-in**. If not installed:

- `PROJECT_SECRET_SCAN_CMD` remains empty
- `verify_secrets()` is never called
- Zero behavioural change from v0.10.0

Installation for users who want it:

```bash
brew install gitleaks        # macOS
go install github.com/gitleaks/gitleaks/v8@latest  # Go
# Or download binary from https://github.com/gitleaks/gitleaks/releases
```

Current stable: **v8.30.0** (November 2025).

---

## What Wave 4 Does NOT Include

Items deferred to future waves per the always-forward analysis roadmap:

| Item | Original Wave | Reason for deferral |
|------|--------------|---------------------|
| Review severity classification | Wave 4 (original) | Completed in Wave 3 via `_classify_security_severity()` |
| `DIMINISHING_RETURNS_THRESHOLD` configurability | Wave 4 (original) | Low priority; current hardcoded value (3) is working well |
| `FORCE_ADVANCE_ON_REVIEW_STALL=true` flip | Wave 5 | Needs review severity classification (Wave 3 ✓) + testing |
| `FORCE_ADVANCE_ON_DIMINISHING_RETURNS=true` flip | Wave 5 | Needs configurable threshold + rate math |
| Active notification on security skip | Wave 6 | Requires Slack/email integration |
| Deferred-FR tracking | Wave 6 | Requires significant requirements gate refactor |
| Broad-scope file refactoring (autopilot.sh, autopilot-lib.sh, autopilot-prompts.sh 500-line compliance) | Wave 5 | Pre-existing violation; orthogonal to Wave 4 scope; requires coordinated effort across 4 files |

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Gitleaks not installed on CI runner | Medium | None — graceful skip | Opt-in via `PROJECT_SECRET_SCAN_CMD`; detection is automatic |
| False positives from gitleaks | Medium | Low — enters fix loop | Three-layer prevention: (1) branch-scoping excludes pre-existing files, (2) auto-generated .gitleaks.toml allowlists filter common stopwords/paths, (3) Tier 2 fix loop lets Claude handle remaining FPs via .gitleaksignore |
| Branch-scoped skip detection misses files | Low | Low — reverts to full scan | Fallback to full-repo scan on any git error |
| Tier 1 classification too broad | Low | Medium — unnecessary halts | Configurable via `PROJECT_SECRET_TIER1_RULES`; conservative default list |
| `jq` not available | Low | Low | Fallback to grep/awk parsing |
| Finalize gap — secrets introduced during post-merge fixes | Low | Low — pre-merge scan passed; Claude introducing secrets in fix phase is improbable | Accepted risk; optionally add `verify_secrets()` call to finalize in a future wave |
| .gitleaksignore fingerprint portability | Low | Low — mitigated by three-tier suppression | Always invoke gitleaks from repo root with `.` path; prefer .gitleaks.toml allowlists over .gitleaksignore |
| detect-project.sh extraction refactor | Low | Low — extraction is mechanical | Follow established pattern (autopilot-verify.sh extraction); test sourcing chain after extraction |
| Path A repos skip secret scanning | Low | Medium — secrets undetected | Document in README that Path A repos with custom CI should add their own secret scanning |
| --max-decode-depth=1 misses multi-layer encoded secrets | Low | Low — most working-tree secrets are plaintext | Acceptable trade-off: depth=1 catches single-layer base64; depth=5 risks OOM (gitleaks #2019) |
| install.sh missing new file | Medium | High — project detection breaks | Add `autopilot-detect-tools.sh` to explicit file list at line 116; add extraction test assertion (following `test-gates-extraction.sh` pattern from commit `4ee4183`); consider adding src→install completeness validation test |

---

## Resolved Questions

### Q1: Scan mode default — RESOLVED: `"branch"`

**Decision:** `PROJECT_SECRET_SCAN_MODE="branch"` (scan only branch-changed files)

**Evidence:**
- Always-forward analysis (line 476-480) explicitly endorses branch-scoping: "narrower scope = fewer false halts"
- All existing gate prompts already use branch-scoped patterns (`git diff --name-only` in review, requirements, test-mod detection)
- ADflair consumer repo has `infra/.env.prod.example` with `AWS_ACCESS_KEY_ID=CHANGE_ME` — full-repo scanning would flag this every epic as a false positive
- Squash merge strategy (used by ADflair) means branch history is collapsed — scanning only current state aligns with what actually gets merged
- `"full"` mode remains available via `project.env` override for compliance-focused repos

### Q2: Git history vs working tree — RESOLVED: Working tree (`gitleaks dir`)

**Decision:** Use `(cd "$repo_root" && gitleaks dir .)` to scan current file state

**Evidence:**
- Existing security-review phase (`autopilot-prompts.sh:509`) scans current files, not git history — consistent approach
- Secrets removed before merge are not a deployment risk — the merged state is what matters
- ADflair uses squash merges — scanning intermediate commits via git history is wasted work when those commits are squashed away
- `gitleaks dir` is faster (no git history traversal) and produces fewer false positives from WIP commits where a developer temporarily pasted a key then removed it
- If a secret was committed and pushed, GitHub push protection (enabled by default on public repos since 2024) catches it server-side regardless

### Q3: Pre-commit hook distribution — RESOLVED: Recommend but don't generate

**Decision:** Log a recommendation when gitleaks is detected; don't auto-generate or auto-install hooks

**Evidence:**
- OWASP identifies pre-commit as "the best location" for secret detection — before secrets enter git history at all
- However, pre-commit hooks are bypassable (`--no-verify`), require local installation, and are outside autopilot's CI-enforcement scope
- Truffle Security research: "When trying to impose rules that are too constraining, people will bend them" — auto-installing hooks causes `--no-verify` to become habitual
- GitHub push protection (server-side, unbypassable) is the better complement to CI scanning than local hooks
- **Implementation:** Covered in Section 1.4 — pre-commit tip emitted during auto-detection.

### Q4: Custom `.gitleaks.toml` — RESOLVED: Generate minimal config with `useDefault = true`

**Decision:** Generate a starter `.gitleaks.toml` that extends defaults with project-appropriate allowlists

**Evidence:**
- Default rules (264+ rules) are well-maintained and updated frequently — should NOT be replaced
- But ADflair's `infra/.env.prod.example` contains `AWS_ACCESS_KEY_ID=CHANGE_ME` which triggers false positives with defaults
- Enterprise users "almost always need customization" (Gitleaks for Enterprises blog) — primarily path allowlists and stopwords
- Gitleaks supports `[extend] useDefault = true` to layer custom config on top of defaults

**Implementation:** Covered in Section 1.4 — .gitleaks.toml auto-generated during project detection.

### Q5: Tier 1 list completeness — RESOLVED: Expand from 10 to 26 rules

**Decision:** Expand the Tier 1 (immediate HALT) list to 26 rules based on unique-prefix criterion

**Rationale:** Every Tier 1 rule must have a **unique provider prefix** = zero/near-zero false positive risk. This is the critical criterion — if a pattern could false-positive on legitimate code, it belongs in Tier 2 (fix loop).

**Final Tier 1 list (26 rules):**

| # | Rule ID | Prefix | Category |
|---|---------|--------|----------|
| 1 | `aws-access-token` | `AKIA/ASIA/ABIA/ACCA` | Cloud (AWS) |
| 2 | `gcp-service-account` | GCP service account JSON | Cloud (GCP) | *(inactive upstream — see note below)* |
| 3 | `gcp-api-key` | `AIza` | Cloud (GCP) |
| 4 | `digitalocean-pat` | `dop_v1_` | Cloud (DO) |
| 5 | `cloudflare-origin-ca-key` | `v1.0-` | Cloud (Cloudflare) |
| 6 | `private-key` | `-----BEGIN.*PRIVATE KEY-----` | Cryptographic |
| 7 | `age-secret-key` | `AGE-SECRET-KEY-1` | Cryptographic |
| 8 | `github-pat` | `ghp_` | Source control |
| 9 | `github-fine-grained-pat` | `github_pat_` | Source control |
| 10 | `github-app-token` | `ghu_/ghs_` | Source control |
| 11 | `github-oauth` | `gho_` | Source control |
| 12 | `github-refresh-token` | `ghr_` | Source control |
| 13 | `gitlab-pat` | `glpat-` | Source control |
| 14 | `gitlab-ptt` | `glptt-` | CI/CD |
| 15 | `gitlab-runner-authentication-token` | `glrt-` | CI/CD |
| 16 | `stripe-access-token` | `sk_live_/rk_live_/sk_test_/rk_test_` | Payments |
| 17 | `slack-bot-token` | `xoxb-` | Communication |
| 18 | `slack-user-token` | `xoxp-` | Communication |
| 19 | `slack-webhook-url` | `hooks.slack.com` | Communication |
| 20 | `openai-api-key` | `sk-proj-` | AI/ML |
| 21 | `anthropic-api-key` | `sk-ant-api03-` | AI/ML |
| 22 | `anthropic-admin-api-key` | `sk-ant-admin01-` | AI/ML |
| 23 | `sendgrid-api-token` | `SG.` | Email |
| 24 | `npm-access-token` | `npm_` | Supply chain |
| 25 | `pypi-upload-token` | `pypi-AgEIcHlwaS5vcmc` | Supply chain |
| 26 | `shopify-access-token` | `shpat_` | E-commerce |

**Note on `gcp-service-account`:** This rule is fully removed from the gitleaks default config (not merely commented out). GCP service account keys are still caught by the `private-key` rule — they contain `-----BEGIN RSA PRIVATE KEY-----`. PR [#1930](https://github.com/gitleaks/gitleaks/pull/1930) to re-add `gcp-service-account` has been open since August 2025 but is not yet merged. Keeping it in our Tier 1 list is harmless: a phantom RuleID never matches, so it cannot cause false positives or pipeline disruption. It provides forward compatibility — when PR #1930 merges and users upgrade gitleaks, the rule auto-activates in our classification with zero config changes.

**Key additions over original 10:**
- **ADflair-specific** (5): `openai-api-key`, `anthropic-api-key`, `anthropic-admin-api-key`, `cloudflare-origin-ca-key`, `age-secret-key` — literally used in the consumer repo
- **Source control** (3): `github-app-token`, `github-oauth`, `github-refresh-token`
- **Supply chain** (2): `npm-access-token`, `pypi-upload-token`
- **CI/CD attack surface** (2): `gitlab-ptt`, `gitlab-runner-authentication-token`
- **Common SaaS with unique prefixes** (4): `gcp-api-key`, `sendgrid-api-token`, `digitalocean-pat`, `shopify-access-token`

**Explicitly excluded from Tier 1** (stay Tier 2):
- `generic-api-key` — entropy-based, high false-positive rate
- `jwt` / `jwt-base64` — `ey` prefix too common; many JWTs are short-lived
- `heroku-api-key` (v1) — UUID pattern, no unique prefix
- `*-client-id` rules — client IDs often public/non-secret
- Database connection strings — no standardized prefix; caught by generic patterns
- `stripe-access-token` with `sk_test_` — test keys have lower blast radius but are still caught by the rule (the rule matches both `sk_live_` and `sk_test_`). This is acceptable — test key rotation is low-cost and the rule has zero false positives.

**Configurability:** `PROJECT_SECRET_TIER1_RULES` in `project.env` allows overriding the default list for repos with custom provider patterns or stricter/looser requirements.

### Q6: Gitleaks CLI syntax — RESOLVED: Positional argument, not `--source`

**Decision:** Use `gitleaks dir .` (positional argument) from within `$repo_root`, not `gitleaks dir --source "$repo_root"`

**Evidence:**
- `--source` flag only exists on the deprecated `detect` command (removed from help in v8.19.0)
- Using `--source` with `dir` causes hard failure (exit code 126: "unknown flag")
- `dir` command uses positional `[path]` argument, defaulting to `.` ([gitleaks source: cmd/directory.go](https://github.com/gitleaks/gitleaks/blob/master/cmd/directory.go))
- Running from repo root with `.` ensures fingerprints use relative paths, fixing portability issue [#1287](https://github.com/gitleaks/gitleaks/issues/1287)
- `--max-decode-depth=1` added to prevent OOM from code default of 5 (README documents 0; see [#2019](https://github.com/gitleaks/gitleaks/issues/2019)); depth=1 catches single-layer base64 encoding without deep recursion risk
