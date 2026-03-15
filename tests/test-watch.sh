#!/usr/bin/env bash
# test-watch.sh — Unit tests for autopilot-watch.sh helper and parser functions
set -euo pipefail

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/../src"

# ─── Test Framework ─────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected '$expected', got '$actual'"
    fi
}

assert_gt() {
    local val="$1" threshold="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$val" -gt "$threshold" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected '$val' > '$threshold'"
    fi
}

assert_exit() {
    local expected="$1" actual="$2" msg="${3:-}"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  ✓ $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo "  ✗ $msg: expected exit $expected, got $actual"
    fi
}

# ─── Stubs ──────────────────────────────────────────────────────────────────

safe_tput() { :; }
log() { :; }

# ─── Tmpdir setup ──────────────────────────────────────────────────────────

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# ─── Section 1: format_duration ────────────────────────────────────────────

echo "Section 1: format_duration"

eval "$(sed -n '/^format_duration()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

assert_eq "0s"    "$(format_duration 0)"     "0 seconds"
assert_eq "1s"    "$(format_duration 1)"     "1 second"
assert_eq "59s"   "$(format_duration 59)"    "59 seconds"
assert_eq "1m00s" "$(format_duration 60)"    "60s = 1m00s"
assert_eq "1m01s" "$(format_duration 61)"    "61s = 1m01s"
assert_eq "59m59s" "$(format_duration 3599)" "3599s = 59m59s"
assert_eq "1h00m" "$(format_duration 3600)"  "3600s = 1h00m"
assert_eq "1h01m" "$(format_duration 3661)"  "3661s = 1h01m"
assert_eq "24h00m" "$(format_duration 86400)" "86400s = 24h00m"
assert_eq "0s"    "$(format_duration)"       "no args = 0s"

# ─── Section 2: format_tokens ──────────────────────────────────────────────

echo ""
echo "Section 2: format_tokens"

eval "$(sed -n '/^format_tokens()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

assert_eq "0"    "$(format_tokens 0)"      "0 tokens"
assert_eq "500"  "$(format_tokens 500)"    "500 tokens"
assert_eq "999"  "$(format_tokens 999)"    "999 tokens"
assert_eq "1k"   "$(format_tokens 1000)"   "1000 = 1k"
assert_eq "1k"   "$(format_tokens 1999)"   "1999 = 1k"
assert_eq "2k"   "$(format_tokens 2000)"   "2000 = 2k"
assert_eq "150k" "$(format_tokens 150000)" "150000 = 150k"
assert_eq "0"    "$(format_tokens)"        "no args = 0"

# ─── Section 3: short_phase ───────────────────────────────────────────────

echo ""
echo "Section 3: short_phase"

eval "$(sed -n '/^short_phase()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

assert_eq "clarify-v"  "$(short_phase clarify-verify)"       "clarify-verify"
assert_eq "analyze-v"  "$(short_phase analyze-verify)"       "analyze-verify"
assert_eq "design"     "$(short_phase design-read)"          "design-read"
assert_eq "verify-req" "$(short_phase verify-requirements)"  "verify-requirements"
assert_eq "req-rchk"   "$(short_phase requirements-recheck)" "requirements-recheck"
assert_eq "sec-review" "$(short_phase security-review)"      "security-review"
assert_eq "verify-ci"  "$(short_phase verify-ci)"            "verify-ci"
assert_eq "sec-verify" "$(short_phase security-verify)"      "security-verify"
assert_eq "final-fix"  "$(short_phase finalize-fix)"         "finalize-fix"
assert_eq "final-rev"  "$(short_phase finalize-review)"      "finalize-review"
assert_eq "req-fix"    "$(short_phase requirements-fix)"     "requirements-fix"
assert_eq "sec-fix"    "$(short_phase security-fix)"         "security-fix"
assert_eq "self-rev"   "$(short_phase self-review)"          "self-review"
assert_eq "ci-fix"     "$(short_phase verify-ci-fix)"        "verify-ci-fix"
assert_eq "conflict-r" "$(short_phase conflict-resolve)"     "conflict-resolve"
assert_eq "crystal."   "$(short_phase crystallize)"          "crystallize"
assert_eq "specify"    "$(short_phase specify)"              "specify passthrough"
assert_eq "implement"  "$(short_phase implement)"            "implement passthrough"
assert_eq "unknown-phase" "$(short_phase unknown-phase)"     "unknown passthrough"
assert_eq ""           "$(short_phase "")"                   "empty passthrough"

# ─── Section 4: iso_to_epoch ──────────────────────────────────────────────

echo ""
echo "Section 4: iso_to_epoch"

eval "$(sed -n '/^iso_to_epoch()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

assert_eq "0" "$(iso_to_epoch "")" "empty string → 0"

naive=$(iso_to_epoch "2026-01-01T00:00:00")
assert_gt "$naive" 0 "naive ts → non-zero epoch"

zulu=$(iso_to_epoch "2026-01-01T00:00:00Z")
assert_eq "$naive" "$zulu" "zulu == naive (TZ stripped)"

plus=$(iso_to_epoch "2026-01-01T00:00:00+05:30")
assert_eq "$naive" "$plus" "+offset == naive (TZ stripped)"

minus=$(iso_to_epoch "2026-01-01T00:00:00-08:00")
assert_eq "$naive" "$minus" "-offset == naive (TZ stripped)"

assert_eq "0" "$(iso_to_epoch "not-a-date")" "invalid → 0"

# Consistency cross-check
plus00=$(iso_to_epoch "2026-01-01T00:00:00+00:00")
assert_eq "$naive" "$plus00" "naive == zulu == +00:00"

# ─── Section 5: pid_alive ─────────────────────────────────────────────────

echo ""
echo "Section 5: pid_alive"

eval "$(sed -n '/^pid_alive()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

rc=0; pid_alive $$ || rc=$?
assert_exit "0" "$rc" "current shell PID alive"

rc=0; pid_alive 999999 || rc=$?
assert_exit "1" "$rc" "nonexistent PID 999999"

rc=0; pid_alive "" || rc=$?
assert_exit "1" "$rc" "empty PID"

# Run background pid tests in a subshell to avoid signal/trap interference
_bg_result=$(bash -c '
pid_alive() { local pid="${1:-}"; [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; }
sleep 60 & bg=$!
rc=0; pid_alive "$bg" || rc=$?; echo "alive=$rc"
kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null || true
rc=0; pid_alive "$bg" || rc=$?; echo "dead=$rc"
' 2>/dev/null)
_alive_rc=$(echo "$_bg_result" | grep '^alive=' | cut -d= -f2)
_dead_rc=$(echo "$_bg_result" | grep '^dead=' | cut -d= -f2)
assert_exit "0" "$_alive_rc" "background sleep alive"
assert_exit "1" "$_dead_rc" "killed process dead"

# ─── Section 6: read_status ───────────────────────────────────────────────

echo ""
echo "Section 6: read_status"

eval "$(sed -n '/^read_status()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

# 6.1 Missing file
STATUS_FILE="$TMPDIR_ROOT/nonexistent.json"
rc=0; read_status || rc=$?
assert_exit "1" "$rc" "missing file returns 1"
assert_eq "" "$STATUS_EPIC" "missing file → empty epic"

# 6.2 Valid full JSON
STATUS_FILE="$TMPDIR_ROOT/status-full.json"
cat > "$STATUS_FILE" <<'JSON'
{"epic":"001","phase":"implement","cost_usd":1.5,"tokens":{"input":50000,"output":25000},"last_tool":"bash","pid":12345,"last_activity_at":"2026-03-15T10:00:00Z","implement_progress":{"current_phase":3,"total_phases":8,"tasks_complete":5,"tasks_remaining":3,"tasks_deferred":1}}
JSON
read_status
assert_eq "001"       "$STATUS_EPIC"          "full: epic"
assert_eq "implement" "$STATUS_PHASE"         "full: phase"
assert_eq "1.5"       "$STATUS_COST"          "full: cost"
assert_eq "50000"     "$STATUS_TOKENS_IN"     "full: tokens_in"
assert_eq "25000"     "$STATUS_TOKENS_OUT"    "full: tokens_out"
assert_eq "bash"      "$STATUS_LAST_TOOL"     "full: last_tool"
assert_eq "12345"     "$STATUS_PID"           "full: pid"
assert_eq "3"         "$IMPL_CURRENT_PHASE"   "full: impl current_phase"
assert_eq "8"         "$IMPL_TOTAL_PHASES"    "full: impl total_phases"
assert_eq "5"         "$IMPL_TASKS_COMPLETE"  "full: impl tasks_complete"
assert_eq "3"         "$IMPL_TASKS_REMAINING" "full: impl tasks_remaining"
assert_eq "1"         "$IMPL_TASKS_DEFERRED"  "full: impl tasks_deferred"

# 6.3 Minimal JSON (nulls)
STATUS_FILE="$TMPDIR_ROOT/status-min.json"
cat > "$STATUS_FILE" <<'JSON'
{"epic":"002","phase":"specify"}
JSON
read_status
assert_eq "002"     "$STATUS_EPIC"      "minimal: epic"
assert_eq "specify" "$STATUS_PHASE"     "minimal: phase"
assert_eq "0"       "$STATUS_COST"      "minimal: cost defaults 0"
assert_eq "0"       "$STATUS_TOKENS_IN" "minimal: tokens_in defaults 0"
assert_eq "0"       "$STATUS_TOKENS_OUT" "minimal: tokens_out defaults 0"

# 6.4 Missing implement_progress
STATUS_FILE="$TMPDIR_ROOT/status-no-impl.json"
cat > "$STATUS_FILE" <<'JSON'
{"epic":"003","phase":"clarify","cost_usd":0.5,"tokens":{"input":1000,"output":500},"last_tool":"","pid":99,"last_activity_at":"2026-03-15T10:00:00Z"}
JSON
read_status
assert_eq "" "$IMPL_CURRENT_PHASE"  "no impl_progress: current_phase empty"
assert_eq "" "$IMPL_TASKS_COMPLETE" "no impl_progress: tasks_complete empty"

# 6.5 Zero cost/tokens
STATUS_FILE="$TMPDIR_ROOT/status-zero.json"
cat > "$STATUS_FILE" <<'JSON'
{"epic":"004","phase":"specify","cost_usd":0,"tokens":{"input":0,"output":0},"last_tool":"","pid":1,"last_activity_at":""}
JSON
read_status
assert_eq "0" "$STATUS_COST"      "zero: cost"
assert_eq "0" "$STATUS_TOKENS_IN" "zero: tokens_in"
assert_eq "0" "$STATUS_TOKENS_OUT" "zero: tokens_out"

# 6.6 Invalid JSON
STATUS_FILE="$TMPDIR_ROOT/status-broken.json"
echo '{broken' > "$STATUS_FILE"
rc=0; read_status || rc=$?
assert_exit "1" "$rc" "invalid JSON returns 1"

# ─── Section 7: read_phase_timeline ───────────────────────────────────────

echo ""
echo "Section 7: read_phase_timeline"

PHASES=(specify clarify clarify-verify plan design-read tasks analyze analyze-verify implement verify-requirements requirements-fix requirements-recheck security-review security-fix security-verify verify-ci verify-ci-fix review self-review review-fix rebase-fix conflict-resolve finalize-fix finalize-review crystallize)

eval "$(sed -n '/^read_phase_timeline()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

# 7.1 Missing events file
EVENTS_FILE="$TMPDIR_ROOT/nonexistent.jsonl"
STATUS_EPIC="001"
TIMELINE_PHASES=() TIMELINE_DURATIONS=() TIMELINE_COSTS=() TIMELINE_ITERS=()
read_phase_timeline
assert_eq "0" "${#TIMELINE_PHASES[@]}" "missing file → empty timeline"

# 7.2 Empty STATUS_EPIC
EVENTS_FILE="$TMPDIR_ROOT/events.jsonl"
touch "$EVENTS_FILE"
STATUS_EPIC=""
read_phase_timeline
assert_eq "0" "${#TIMELINE_PHASES[@]}" "empty epic → empty timeline"

# 7.3 Single phase
EVENTS_FILE="$TMPDIR_ROOT/events-single.jsonl"
STATUS_EPIC="001"
cat > "$EVENTS_FILE" <<'JSONL'
{"ts":"2026-03-15T10:00:00Z","event":"phase_start","epic":"001","phase":"specify"}
{"ts":"2026-03-15T10:05:00Z","event":"phase_end","epic":"001","phase":"specify","duration_ms":300000,"cost_usd":0.05}
JSONL
read_phase_timeline
assert_eq "1"       "${#TIMELINE_PHASES[@]}"    "single: 1 phase"
assert_eq "specify" "${TIMELINE_PHASES[0]}"     "single: phase is specify"
assert_eq "300000"  "${TIMELINE_DURATIONS[0]}"  "single: duration"

# 7.4 Multiple phases
EVENTS_FILE="$TMPDIR_ROOT/events-multi.jsonl"
cat > "$EVENTS_FILE" <<'JSONL'
{"ts":"2026-03-15T10:00:00Z","event":"phase_start","epic":"001","phase":"specify"}
{"ts":"2026-03-15T10:05:00Z","event":"phase_end","epic":"001","phase":"specify","duration_ms":300000,"cost_usd":0.05}
{"ts":"2026-03-15T10:06:00Z","event":"phase_start","epic":"001","phase":"clarify"}
{"ts":"2026-03-15T10:16:00Z","event":"phase_end","epic":"001","phase":"clarify","duration_ms":600000,"cost_usd":0.10}
JSONL
read_phase_timeline
assert_eq "2"       "${#TIMELINE_PHASES[@]}"  "multi: 2 phases"
assert_eq "specify" "${TIMELINE_PHASES[0]}"   "multi: first is specify"
assert_eq "clarify" "${TIMELINE_PHASES[1]}"   "multi: second is clarify"

# 7.5 Multi-iteration (same phase twice)
EVENTS_FILE="$TMPDIR_ROOT/events-iter.jsonl"
cat > "$EVENTS_FILE" <<'JSONL'
{"ts":"2026-03-15T10:00:00Z","event":"phase_start","epic":"001","phase":"clarify"}
{"ts":"2026-03-15T10:01:00Z","event":"phase_end","epic":"001","phase":"clarify","duration_ms":100000,"cost_usd":0.03}
{"ts":"2026-03-15T10:02:00Z","event":"phase_start","epic":"001","phase":"clarify"}
{"ts":"2026-03-15T10:05:00Z","event":"phase_end","epic":"001","phase":"clarify","duration_ms":200000,"cost_usd":0.04}
JSONL
read_phase_timeline
assert_eq "300000" "${TIMELINE_DURATIONS[0]}" "iter: accumulated duration"
assert_eq "2"      "${TIMELINE_ITERS[0]}"     "iter: 2 iterations"

# ─── Section 8: read_recent_activity ──────────────────────────────────────

echo ""
echo "Section 8: read_recent_activity"

eval "$(sed -n '/^read_recent_activity()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

# 8.1 Missing events file
EVENTS_FILE="$TMPDIR_ROOT/nonexistent-activity.jsonl"
ACTIVITY_TOOLS=() ACTIVITY_TIMES=() ACTIVITY_TARGETS=()
read_recent_activity
assert_eq "0" "${#ACTIVITY_TOOLS[@]}" "missing file → empty activity"

# 8.2 Single tool_use
EVENTS_FILE="$TMPDIR_ROOT/activity-single.jsonl"
cat > "$EVENTS_FILE" <<'JSONL'
{"ts":"2026-03-15T10:05:42Z","event":"tool_use","tool":"bash","target":"npm test"}
JSONL
read_recent_activity
assert_eq "1"       "${#ACTIVITY_TOOLS[@]}"   "single: 1 tool"
assert_eq "bash"    "${ACTIVITY_TOOLS[0]}"    "single: tool is bash"
assert_eq "10:05:42Z" "${ACTIVITY_TIMES[0]}"   "single: time extracted"

# 8.3 More than 10 events → capped at 10
EVENTS_FILE="$TMPDIR_ROOT/activity-many.jsonl"
: > "$EVENTS_FILE"
for i in $(seq 1 12); do
    printf '{"ts":"2026-03-15T10:%02d:00Z","event":"tool_use","tool":"bash","target":"cmd %d"}\n' "$i" "$i" >> "$EVENTS_FILE"
done
read_recent_activity
assert_eq "10" "${#ACTIVITY_TOOLS[@]}" "capped at 10 entries"

# 8.4 Mixed events — only tool_use extracted
EVENTS_FILE="$TMPDIR_ROOT/activity-mixed.jsonl"
cat > "$EVENTS_FILE" <<'JSONL'
{"ts":"2026-03-15T10:00:00Z","event":"phase_start","epic":"001","phase":"specify"}
{"ts":"2026-03-15T10:01:00Z","event":"tool_use","tool":"Read","target":"file.ts"}
{"ts":"2026-03-15T10:02:00Z","event":"phase_end","epic":"001","phase":"specify","duration_ms":120000,"cost_usd":0.01}
{"ts":"2026-03-15T10:03:00Z","event":"tool_use","tool":"Edit","target":"file.ts"}
JSONL
read_recent_activity
assert_eq "2" "${#ACTIVITY_TOOLS[@]}" "mixed: only 2 tool_use events"

# ─── Section 9: read_epic_title ───────────────────────────────────────────

echo ""
echo "Section 9: read_epic_title"

eval "$(sed -n '/^read_epic_title()/,/^}/p' "$SRC_DIR/autopilot-watch.sh")"

REPO_ROOT="$TMPDIR_ROOT"

# 9.1 Empty STATUS_EPIC
STATUS_EPIC=""
EPIC_TITLE="dirty"
read_epic_title
assert_eq "" "$EPIC_TITLE" "empty epic → empty title"

# 9.2 Valid epic file with quoted title
STATUS_EPIC="001"
mkdir -p "$REPO_ROOT/docs/specs/epics"
cat > "$REPO_ROOT/docs/specs/epics/epic-001-test.md" <<'MD'
---
title: "Auth System"
---
MD
read_epic_title || true
assert_eq "Auth System" "$EPIC_TITLE" "quoted title extracted"

# 9.3 Title without quotes
cat > "$REPO_ROOT/docs/specs/epics/epic-001-test.md" <<'MD'
---
title: Auth System
---
MD
read_epic_title || true
assert_eq "Auth System" "$EPIC_TITLE" "unquoted title extracted"

# 9.4 No matching file → fallback
rm -f "$REPO_ROOT/docs/specs/epics/epic-001-test.md"
read_epic_title || true
assert_eq "Epic 001" "$EPIC_TITLE" "no file → fallback title"

# ─── Section 10: Phase sync validation ────────────────────────────────────

echo ""
echo "Section 10: Phase sync validation"

# 10.1 Every PHASES entry produces non-empty short_phase
all_short_ok=true
for p in "${PHASES[@]}"; do
    result=$(short_phase "$p")
    if [[ -z "$result" ]]; then
        all_short_ok=false
        echo "  ✗ short_phase('$p') returned empty" >&2
    fi
done
TESTS_RUN=$((TESTS_RUN + 1))
if $all_short_ok; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ all PHASES produce non-empty short_phase"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ some PHASES produce empty short_phase"
fi

# 10.2 Every PHASE_MODEL key appears in PHASES (except verify-ci — it's in
# PHASES but intentionally absent from PHASE_MODEL; we test the reverse)
phase_model_keys=$(sed -n '/^declare -A PHASE_MODEL/,/^)/p' "$SRC_DIR/autopilot.sh" \
    | grep -oE '\[[a-z-]+\]' | tr -d '[]')
phases_str=" ${PHASES[*]} "
all_in_phases=true
for k in $phase_model_keys; do
    if [[ "$phases_str" != *" $k "* ]]; then
        all_in_phases=false
        echo "  ✗ PHASE_MODEL key '$k' not in PHASES" >&2
    fi
done
TESTS_RUN=$((TESTS_RUN + 1))
if $all_in_phases; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✓ all PHASE_MODEL keys present in PHASES"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo "  ✗ some PHASE_MODEL keys missing from PHASES"
fi

# ─── Results ──────────────────────────────────────────────────────────────

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
