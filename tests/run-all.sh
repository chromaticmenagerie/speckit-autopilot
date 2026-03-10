#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail_fast=false
filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--fail-fast) fail_fast=true; shift ;;
    -t|--filter)    filter="$2"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

passed=0
failed=0
total=0
declare -a failures=()

for test_file in "$SCRIPT_DIR"/test-*.sh; do
  name="$(basename "$test_file")"
  [[ -n "$filter" && "$name" != *"$filter"* ]] && continue

  total=$((total + 1))
  start=$(date +%s)
  bash "$test_file" >/dev/null 2>&1
  rc=$?
  elapsed=$(( $(date +%s) - start ))

  if [[ $rc -eq 0 ]]; then
    passed=$((passed + 1))
    printf "  PASS  %-45s (%ds)\n" "$name" "$elapsed"
  else
    failed=$((failed + 1))
    failures+=("$name")
    printf "  FAIL  %-45s (%ds, exit %d)\n" "$name" "$elapsed" "$rc"
    $fail_fast && break
  fi
done

echo ""
echo "Results: $passed passed, $failed failed, $total total"

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  echo "Failed tests:"
  for f in "${failures[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
