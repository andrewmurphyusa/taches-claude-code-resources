#!/bin/bash
# capacity-gemini.sh — Gemini (Antigravity/Google) capacity fetcher for Ralph Orchestrator
#
# Implements the standard capacity-script interface expected by capacity-monitor.sh:
#   CAPACITY_5H_REMAINING_PCT     — percentage of 5-hour window remaining (0-100)
#   CAPACITY_5H_RESET_EPOCH       — Unix epoch when 5h window resets (-1 if unknown)
#   CAPACITY_WEEKLY_REMAINING_PCT — percentage of 7-day window remaining (0-100)
#   CAPACITY_WEEKLY_RESET_EPOCH   — Unix epoch when weekly window resets (-1 if unknown)
#
# Phase 1 (current): stub returning 100% / -1.
#   Gemini CLI has no proactive capacity API accessible via shell script.
#   (The interactive /stats model slash command is not scriptable.)
#   Actual exhaustion is detected reactively via error pattern matching in error-handler.sh.
#
# Phase 4 upgrade path:
#   fetch_gemini_capacity() reads /tmp/ralph-gemini-reset.epoch (written by orchestrator.sh
#   on USAGE_EXHAUSTED) and parses "retryDelay" from /tmp/ralph-gemini-last-error.json
#   (written by the Gemini CLI error response) when present.
#   This is an epoch-file approach (no live query), because Gemini lacks a /status command.
#
# Reactive error patterns handled by error-handler.sh classify_error():
#   RATE_LIMIT:      "Rate Limit Exceeded" | "Quota exceeded for quota metric"
#                    | "RATE_LIMIT_EXCEEDED"
#   USAGE_EXHAUSTED: "TerminalQuotaError" | "daily quota" | "RESOURCE_EXHAUSTED"
#
# Note: invoke via gemini CLI binary (not antigravity binary) for headless execution:
#   gemini --model <model-id> -p "$(cat prompt.md)"
#   The -p flag triggers headless mode automatically; exit 0 = success, exit 1 = error.
#
# Designed to be sourced by capacity-monitor.sh (not executed directly).

# Estimate file: persists reset epoch between runs when written by orchestrator.sh
_GEMINI_ESTIMATE_FILE="/tmp/ralph-gemini-reset.epoch"
_GEMINI_LAST_ERROR_FILE="/tmp/ralph-gemini-last-error.json"

# ============================================================================
# PUBLIC FUNCTIONS
# ============================================================================

# fetch_gemini_capacity — sets four standard CAPACITY_* variables in caller scope.
# Returns 0 on success, 1 on failure.
#
# Phase 4 implementation: reads epoch file written by orchestrator.sh on USAGE_EXHAUSTED.
# Parses retryDelay from Gemini API error JSON response when available.
fetch_gemini_capacity() {
  local now
  now=$(date +%s)
  local reset_epoch=-1

  # Try to parse retryDelay from last error JSON (Gemini API includes "retryDelay": "Xs")
  if [ -f "$_GEMINI_LAST_ERROR_FILE" ]; then
    local retry_delay
    retry_delay=$(python3 -c "
import json, sys
try:
  d = json.load(open('$_GEMINI_LAST_ERROR_FILE'))
  # Gemini error format: error.details[].retryDelay (e.g. '3600s') or retryDelay at root
  delay = None
  if isinstance(d, dict):
    delay = d.get('retryDelay') or d.get('error', {}).get('retryDelay')
    if delay is None:
      for item in d.get('error', {}).get('details', []):
        if 'retryDelay' in item:
          delay = item['retryDelay']
          break
  if delay:
    # Parse 'Xs' or 'Xm' format
    delay = str(delay)
    if delay.endswith('s'):
      print(int(delay[:-1]))
    elif delay.endswith('m'):
      print(int(delay[:-1]) * 60)
    else:
      print(int(delay))
  else:
    print(-1)
except Exception:
  print(-1)
" 2>/dev/null || echo "-1")

    if [ "$retry_delay" -gt 0 ] 2>/dev/null; then
      reset_epoch=$((now + retry_delay))
      # Persist the computed epoch so future calls use it without re-parsing JSON
      echo "$reset_epoch" > "$_GEMINI_ESTIMATE_FILE" 2>/dev/null || true
    fi
  fi

  # Read stored epoch file (may have been written above or by orchestrator.sh)
  if [ -f "$_GEMINI_ESTIMATE_FILE" ]; then
    local stored_epoch
    stored_epoch=$(cat "$_GEMINI_ESTIMATE_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$stored_epoch" ] && [ "$stored_epoch" -gt "$now" ] 2>/dev/null; then
      # Still within exhaustion window: report 0% remaining
      CAPACITY_5H_REMAINING_PCT=0
      CAPACITY_5H_RESET_EPOCH="$stored_epoch"
      CAPACITY_WEEKLY_REMAINING_PCT=100
      CAPACITY_WEEKLY_RESET_EPOCH=-1
      return 0
    else
      # Epoch has passed: remove stale files and report full capacity
      rm -f "$_GEMINI_ESTIMATE_FILE" "$_GEMINI_LAST_ERROR_FILE"
    fi
  fi

  # No exhaustion signal: report full capacity
  CAPACITY_5H_REMAINING_PCT=100
  CAPACITY_5H_RESET_EPOCH=-1
  CAPACITY_WEEKLY_REMAINING_PCT=100
  CAPACITY_WEEKLY_RESET_EPOCH=-1
  return 0
}

# invalidate_gemini_capacity_cache — removes epoch and error files to reset exhaustion state.
# Called from orchestrator.sh USAGE_EXHAUSTED branch after the reset epoch is reached.
invalidate_gemini_capacity_cache() {
  rm -f "$_GEMINI_ESTIMATE_FILE" "$_GEMINI_LAST_ERROR_FILE"
}
