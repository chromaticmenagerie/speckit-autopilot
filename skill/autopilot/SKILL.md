---
name: autopilot
description: >
  Launch speckit-autopilot autonomous epic lifecycle orchestrator.
  Runs specify, clarify, plan, tasks, analyze, implement, review, merge,
  crystallize, and finalize phases as fresh claude -p invocations.
  Use for: running epics, monitoring progress, dry-run preview.
argument-hint: "[epic-number] [--dry-run] [--no-auto-continue] [--silent]"
disable-model-invocation: true
---

## User Input

```text
$ARGUMENTS
```

## Execution

This command always delegates to the shell script orchestrator at `.specify/scripts/bash/autopilot.sh`. The script handles state detection, fresh context per phase, retry logic, cross-epic looping, and merge automation. No interactive questions — just launch and monitor.

### Step 1: Verify prerequisites

Confirm `.specify/memory/constitution.md` and `.specify/scripts/bash/autopilot.sh` exist (just check, don't dump contents).

### Step 2: Parse arguments and dispatch

**If `$ARGUMENTS` contains `--dry-run`:**

Run synchronously and display the output:

```bash
.specify/scripts/bash/autopilot.sh $ARGUMENTS
```

Report the detected state and what would happen. Done.

**Otherwise (default — full autopilot):**

Launch the orchestrator in the background using Bash with `run_in_background: true`:

```bash
.specify/scripts/bash/autopilot.sh $ARGUMENTS
```

### Step 3: Report launch and monitor

After launching, immediately tell the user:

- Autopilot is running in the background
- Monitor live: `.specify/logs/autopilot-status.json`
- Full log: `.specify/logs/autopilot.log`
- Phase logs: `.specify/logs/{epic}-{phase}.log`
- Epic summaries (after merge): `.specify/logs/{epic}-summary.md`

### Step 4: Poll progress

Read `.specify/logs/autopilot-status.json` periodically (~30s intervals) to report phase transitions. When the background task completes, read the final log entries and any epic summary files to give a completion report.

If the process errors out, read `.specify/logs/autopilot.log` tail to diagnose and report.

## Arguments Reference

All arguments pass through to `autopilot.sh`:

- *(empty)* — auto-detect next unmerged epic, run all remaining epics
- `NNN` — target a specific epic number (e.g., `004`)
- `--dry-run` — preview what would happen without invoking Claude
- `--no-auto-continue` — pause between epics
- `--silent` — suppress live dashboard output (files still written)
