#!/usr/bin/env bash
# run-shell-self-tests.sh — run every shell script's --self-test and print one aligned line per script.
#
# Why this exists
#   Each script prints its own self-test output in its own format: different
#   column widths, different PASS lines, and temporary paths. Read in a row,
#   the output is hard to scan. This runner captures each script's output and
#   prints one row per script with its status, check count, and duration.
#   The full output is printed, indented, only for a script that failed.
#
# Usage
#   run-shell-self-tests.sh <script.sh>...
#
# Exit codes
#   0  every script passed
#   1  at least one script failed, or no script was given

set -uo pipefail

if [[ $# -eq 0 ]]; then
  echo 'usage: run-shell-self-tests.sh <script.sh>...' >&2
  exit 1
fi

width=0
for script in "$@"; do
  [[ ${#script} -gt $width ]] && width=${#script}
done

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

failed=0
checks_total=0
start_all=$SECONDS

for script in "$@"; do
  start=$SECONDS
  bash "$script" --self-test >"$log" 2>&1
  rc=$?
  elapsed=$((SECONDS - start))

  # A script reports its checks either as one "ok    <label>" line each
  # or as a "(N checks)" summary.
  checks="$(grep -c '^ok ' "$log")"
  if [[ "$checks" -eq 0 ]]; then
    checks="$(sed -n 's/.*(\([0-9][0-9]*\) checks).*/\1/p' "$log" | tail -n 1)"
  fi
  if [[ -n "$checks" && "$checks" -gt 0 ]]; then
    checks_total=$((checks_total + checks))
    checks_label="${checks} checks"
  else
    checks_label='-'
  fi

  if [[ $rc -eq 0 ]]; then
    printf '  ✅ PASS  %-*s  %10s  %4ss\n' "$width" "$script" "$checks_label" "$elapsed"
  else
    failed=$((failed + 1))
    printf '  ❌ FAIL  %-*s  %10s  %4ss  exit %s\n' "$width" "$script" "$checks_label" "$elapsed" "$rc"
    sed 's/^/         │ /' "$log"
  fi
done

printf '\n  %s scripts, %s passed, %s failed, %s checks, %ss\n' \
  "$#" "$(($# - failed))" "$failed" "$checks_total" "$((SECONDS - start_all))"

[[ $failed -eq 0 ]]
