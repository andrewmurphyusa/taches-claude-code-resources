#!/bin/bash
# capacity-codex.sh — Codex (OpenAI) capacity fetcher for Ralph Orchestrator
#
# shellcheck disable=SC2034 # the four CAPACITY_* vars are set here in caller
# scope and read by capacity-monitor.sh/orchestrator.sh after sourcing —
# invisible to shellcheck's per-file usage analysis.
#
# Implements the standard capacity-script interface expected by capacity-monitor.sh:
#   CAPACITY_5H_REMAINING_PCT     — percentage of 5-hour window remaining (0-100)
#   CAPACITY_5H_RESET_EPOCH       — Unix epoch when 5h window resets (-1 if unknown)
#   CAPACITY_WEEKLY_REMAINING_PCT — percentage of 7-day window remaining (0-100)
#   CAPACITY_WEEKLY_RESET_EPOCH   — Unix epoch when weekly window resets (-1 if unknown)
#
# Phase 1 (current): stub returning 100% / -1.
#   Codex has no proactive capacity API endpoint equivalent to Claude's OAuth usage URL.
#   Actual exhaustion is detected reactively via error pattern matching in error-handler.sh.
#   The USAGE_EXHAUSTED branch in orchestrator.sh handles pausing on capacity hit.
#
# Phase 4 upgrade path (pending real-world validation):
#   fetch_codex_capacity() will invoke `pty-runner codex -- "/status" "exit"` to query
#   the Codex interactive CLI's /status command, which reports rate limit state.
#   Requires: pty-runner (https://github.com/dmahurin/pty-runner) on PATH.
#   The exact field labels in /status output must be captured empirically before
#   the parser is written (see plan Phase 4 empirical capture step).
#   Falls open (returns 100% / -1) if pty-runner is absent or output is unparseable.
#
# Reactive error patterns handled by error-handler.sh classify_error():
#   RATE_LIMIT:      "rate_limit_exceeded" | "Rate limit reached for .* in organization"
#                    | "please slow down and try again after"
#   USAGE_EXHAUSTED: "5-hour window" | "Codex requests for the 5-hour" | "weekly Codex limit"
#
# Designed to be sourced by capacity-monitor.sh (not executed directly).

# Estimate file: persists reset epoch between runs when written by orchestrator.sh
_CODEX_ESTIMATE_FILE="${RALPH_TMP_DIR:-/tmp}/ralph-codex-reset.epoch"

# ============================================================================
# PUBLIC FUNCTIONS
# ============================================================================

# fetch_codex_capacity — sets four standard CAPACITY_* variables in caller scope.
# Returns 0 on success, 1 on failure.
#
# Phase 1 stub: returns 100% available so capacity-monitor.sh does not block.
# Reactive error handling in orchestrator.sh USAGE_EXHAUSTED branch covers actual exhaustion.
fetch_codex_capacity() {
  # Check if a reset epoch has been written by the orchestrator on a prior USAGE_EXHAUSTED event
  local now
  now=$(date +%s)

  if [ -f "$_CODEX_ESTIMATE_FILE" ]; then
    local stored_epoch
    stored_epoch=$(cat "$_CODEX_ESTIMATE_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$stored_epoch" ] && [ "$stored_epoch" -gt "$now" ] 2>/dev/null; then
      # Still within exhaustion window: report 0% remaining
      CAPACITY_5H_REMAINING_PCT=0
      CAPACITY_5H_RESET_EPOCH="$stored_epoch"
      CAPACITY_WEEKLY_REMAINING_PCT=100
      CAPACITY_WEEKLY_RESET_EPOCH=-1
      return 0
    else
      # Epoch has passed: remove stale file and report full capacity
      rm -f "$_CODEX_ESTIMATE_FILE"
    fi
  fi

  # Phase 1 stub: no proactive API available — assume full capacity.
  # Replace this block with pty-runner /status parsing in Phase 4.
  CAPACITY_5H_REMAINING_PCT=100
  CAPACITY_5H_RESET_EPOCH=-1
  CAPACITY_WEEKLY_REMAINING_PCT=100
  CAPACITY_WEEKLY_RESET_EPOCH=-1
  return 0
}

# invalidate_codex_capacity_cache — removes the estimate file to reset exhaustion state.
# Called from orchestrator.sh USAGE_EXHAUSTED branch after the reset epoch is reached.
invalidate_codex_capacity_cache() {
  rm -f "$_CODEX_ESTIMATE_FILE"
}
