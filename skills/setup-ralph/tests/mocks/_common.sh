#!/usr/bin/env bash
# tests/mocks/_common.sh — shared helpers for tests/mocks/{claude,codex,agy}.
#
# Not an executable mock itself: it is sourced by the per-engine mock scripts
# to avoid duplicating the MOCK_SCENARIO/MOCK_LOG protocol (specs/01-test-harness.md)
# three times. bash 3.2 compatible: no associative arrays, no ${var^^}/${var,,}.

# mock_log_call <argv...>
# Appends a "--- CALL ---" record to $MOCK_LOG containing the full argv and
# full stdin. If MOCK_LOG is unset, still drains stdin (so the caller's pipe
# never blocks) but records nothing.
#
# Stdin handling: only read to EOF when stdin is NOT a terminal. A real
# engine invocation (from ralph.sh, or from bats via `run`/pipes) always has
# stdin redirected, so this reads cleanly; a human running the mock directly
# at an interactive shell won't hang waiting for input that will never come.
mock_log_call() {
  if [ -z "${MOCK_LOG:-}" ]; then
    if [ ! -t 0 ]; then
      cat >/dev/null
    fi
    return 0
  fi

  {
    echo "--- CALL ---"
    echo "ARGV:"
    for a in "$@"; do
      printf '  %s\n' "$a"
    done
  } >> "$MOCK_LOG"

  if [ -t 0 ]; then
    echo "STDIN: (tty attached — not read)" >> "$MOCK_LOG"
  else
    { echo "STDIN:"; cat; echo ""; } >> "$MOCK_LOG"
  fi
}

# mock_scenario_for <ENGINE_UPPER>
# Resolves the effective scenario for this call: a per-engine override
# (MOCK_SCENARIO_<ENGINE_UPPER>) beats the generic MOCK_SCENARIO, which
# defaults to "success". Uses eval for indirect lookup instead of
# declare -A / nameref, both unavailable in bash 3.2.
mock_scenario_for() {
  engine_upper="$1"
  override_var="MOCK_SCENARIO_${engine_upper}"
  override_val=""
  eval "override_val=\"\${${override_var}:-}\""
  if [ -n "$override_val" ]; then
    echo "$override_val"
  else
    echo "${MOCK_SCENARIO:-success}"
  fi
}

# mock_touch_plan
# If $MOCK_TOUCH_PLAN names an existing file, marks the first unchecked task
# line ("- [ ] ...") as done ("- [x] ..."). This simulates what a real engine
# session does when it completes the task it was handed (ralph.sh's own
# get_current_task() picks the same "first unchecked line" via
# `grep '^\s*- \[ \]' | head -1`, so this mirrors that exact selection).
# No-op if MOCK_TOUCH_PLAN is unset, the file is missing, or every task is
# already checked off.
mock_touch_plan() {
  if [ -z "${MOCK_TOUCH_PLAN:-}" ] || [ ! -f "$MOCK_TOUCH_PLAN" ]; then
    return 0
  fi

  mock_touch_plan_tmp="$(mktemp "${RALPH_TMP_DIR:-/tmp}/mock-touch-plan-XXXXXX")"
  awk '
    done == 0 && $0 ~ /^[[:space:]]*- \[ \]/ {
      sub(/\[ \]/, "[x]")
      print
      done = 1
      next
    }
    { print }
  ' "$MOCK_TOUCH_PLAN" > "$mock_touch_plan_tmp" && mv "$mock_touch_plan_tmp" "$MOCK_TOUCH_PLAN"
}

# mock_hang <duration>
# Busy-waits for <duration> seconds using only the bash builtin $SECONDS
# (no external command). Deliberately does NOT call `sleep`: tests/mocks/
# is prepended to PATH, so `sleep` inside a mock would resolve to
# tests/mocks/sleep, which returns instantly — that would silently defeat
# the whole point of the 'hang' scenario (proving a timeout guard kills a
# genuinely stuck engine). Callers wrap invocation in a short timeout, so
# the busy loop only ever runs for a second or two before being killed.
mock_hang() {
  mock_hang_duration="${1:-300}"
  mock_hang_start=$SECONDS
  while [ $((SECONDS - mock_hang_start)) -lt "$mock_hang_duration" ]; do
    :
  done
}

# mock_run <ENGINE_UPPER> <success_line> <usage_line> <rate_line> <auth_line> <overloaded_line>
# Shared scenario dispatch for claude/codex/agy, called after mock_log_call
# has already recorded (and consumed) argv/stdin. <overloaded_line> may be
# empty ("") for engines where the 'overloaded' scenario is not applicable
# (spec 01: claude only) — a generic failure is printed instead so the
# scenario still exits nonzero rather than silently succeeding.
mock_run() {
  mock_run_engine_upper="$1"
  mock_run_success_line="$2"
  mock_run_usage_line="$3"
  mock_run_rate_line="$4"
  mock_run_auth_line="$5"
  mock_run_overloaded_line="$6"

  mock_run_scenario="$(mock_scenario_for "$mock_run_engine_upper")"

  case "$mock_run_scenario" in
    success)
      echo "$mock_run_success_line"
      mock_touch_plan
      exit 0
      ;;
    usage_exhausted)
      echo "$mock_run_usage_line"
      exit 1
      ;;
    rate_limit)
      echo "$mock_run_rate_line"
      exit 1
      ;;
    auth_failure)
      echo "$mock_run_auth_line"
      exit 1
      ;;
    overloaded)
      if [ -n "$mock_run_overloaded_line" ]; then
        echo "$mock_run_overloaded_line"
      else
        echo "MOCK: 'overloaded' scenario is claude-only (spec 01) — $mock_run_engine_upper has no overloaded error string; printing generic failure."
      fi
      exit 1
      ;;
    hang)
      mock_hang 300
      exit 0
      ;;
    *)
      echo "MOCK: unknown MOCK_SCENARIO '$mock_run_scenario' for $mock_run_engine_upper" >&2
      exit 1
      ;;
  esac
}
