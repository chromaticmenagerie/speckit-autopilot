# speckit-autopilot

Autonomous epic lifecycle orchestrator for [Spec Kit](https://github.com/speckit) projects. Runs each phase (specify, clarify, plan, tasks, analyze, implement, review, merge) as a fresh `claude -p` invocation with full context window.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/chromaticmenagerie/speckit-autopilot/main/install.sh | bash
```

**Prerequisites**: Spec Kit must be installed first (`.specify/` directory).

The installer:
- Copies 5 orchestrator scripts to `.specify/scripts/bash/`
- Registers the `/autopilot` skill in `.claude/skills/autopilot/`
- Auto-detects project tooling (Python, Node, Rust, Go) and writes `.specify/project.env`
- Detects your base branch (main/master) for merge operations

## Usage

From Claude Code:

```
/autopilot              # Run all remaining epics
/autopilot 003          # Run specific epic
/autopilot --dry-run    # Preview without invoking Claude
```

Or directly:

```bash
.specify/scripts/bash/autopilot.sh [epic-number] [--dry-run] [--silent] [--no-auto-continue]
```

## How It Works

```
Epic YAML → specify → clarify → plan → tasks → analyze → implement → review → merge → crystallize
                                                                                          ↓
                                                                               next epic or finalize
```

Each phase:
1. Detects current state from filesystem markers (spec.md, plan.md, tasks.md, HTML comments)
2. Invokes `claude -p` with phase-specific prompt, model, and tool permissions
3. Streams NDJSON output for live observability
4. Verifies state advanced before moving on
5. Retries with fresh context on failure (configurable per phase)

Convergence phases (clarify, analyze) loop until zero observations/findings.

After all epics merge, **finalize** runs: test/lint verification, iterative fix loop, cross-epic integration review (Opus), and project summary generation.

## Configuration

`.specify/project.env` (auto-generated, edit as needed):

```bash
PROJECT_TEST_CMD="python3 -m pytest"
PROJECT_LINT_CMD="ruff check ."
PROJECT_WORK_DIR="."
PROJECT_BUILD_CMD=""
PROJECT_FORMAT_CMD=""
BASE_BRANCH="main"
```

## Observability

While running:
- **Live status**: `.specify/logs/autopilot-status.json`
- **Full log**: `.specify/logs/autopilot.log`
- **Phase logs**: `.specify/logs/{epic}-{phase}.log`
- **Event stream**: `.specify/logs/events.jsonl`
- **Epic summaries**: `.specify/logs/{epic}-summary.md`
- **Project summary**: `.specify/logs/project-summary.md`

## Architecture

| Script | Purpose | Lines |
|--------|---------|-------|
| `autopilot.sh` | Main orchestrator, phase dispatch, merge, finalize | ~530 |
| `autopilot-lib.sh` | State detection, epic discovery, logging, verification | ~450 |
| `autopilot-prompts.sh` | Language-agnostic prompt templates per phase | ~350 |
| `autopilot-stream.sh` | NDJSON stream processor, live dashboard | ~290 |
| `autopilot-detect-project.sh` | Project tooling auto-detection | ~150 |

## Upgrade

Re-run the install command. It detects the installed version and only copies files if there's a new version.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI (`claude` command)
- `jq` (for NDJSON stream processing)
- `bash` 4+
- Git

## License

MIT
