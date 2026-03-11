#!/bin/bash
# capacity-monitor.sh — Shared orchestration layer for capacity monitoring
#
# Sources each registered agent's capacity script, calls their fetch functions,
# applies 5-hour and weekly threshold rules, and handles all sleeping (in 30s
# increments with STATUS_FILE checks). Exposes a single public function:
#
#   check_all_agent_capacity — call once per build-mode loop iteration
#
# Depends on:
#   LOG_FILE    — set in orchestrator.sh before this file is sourced
#   STATUS_FILE — set in orchestrator.sh before this file is sourced
#
# Agent extensibility: set RALPH_CAPACITY_AGENTS="claude gemini" and drop a
# capacity-gemini.sh alongside this file. No other changes required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# LOAD AGENT SCRIPTS
# ============================================================================

CAPACITY_AGENTS="${RALPH_CAPACITY_AGENTS:-claude}"

for _agent in $CAPACITY_AGENTS; do
  if [ -f "$SCRIPT_DIR/capacity-${_agent}.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/capacity-${_agent}.sh"
  else
    echo "WARNING: No capacity script for agent '${_agent}' — skipping"
  fi
done

# ============================================================================
# CONSTANTS (all overridable via environment)
# ============================================================================

CAPACITY_5H_CRIT_PCT="${CAPACITY_5H_CRIT_PCT:-5}"    # < 5%  → wait for full reset
CAPACITY_5H_WARN_PCT="${CAPACITY_5H_WARN_PCT:-20}"           # < 20% → sleep 1/3 of reset window
CAPACITY_WEEKLY_WARN_PCT="${CAPACITY_WEEKLY_WARN_PCT:-20}"   # < 20% → conditional work-week pause
CAPACITY_SLEEP_CHUNK="${CAPACITY_SLEEP_CHUNK:-30}"           # max seconds per sleep increment

# ============================================================================
# INTERNAL HELPERS
# ============================================================================

# _capacity_sleep_with_status_check <total_seconds> <label>
# Sleeps for total_seconds total, waking every CAPACITY_SLEEP_CHUNK seconds to
# re-read STATUS_FILE for a stop signal. Calls exit 0 (not return) if a signal
# is found — mirrors the existing stop-signal check at the top of the main loop.
_capacity_sleep_with_status_check() {
  local total_seconds="$1"
  local label="$2"
  local remaining=$total_seconds
  local chunk

  while [ "$remaining" -gt 0 ]; do
    chunk=$CAPACITY_SLEEP_CHUNK
    if [ "$remaining" -lt "$chunk" ]; then chunk=$remaining; fi
    sleep "$chunk"
    remaining=$((remaining - chunk))
    if [ -f "$STATUS_FILE" ] && grep -qiE 'BREAK|INTERRUPT|STOP' "$STATUS_FILE" 2>/dev/null; then
      echo "[CAPACITY] $label — stop signal detected during sleep, exiting"
      echo "=== Orchestrator stopped via RALPH_STATUS.txt $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
      exit 0
    fi
  done
}

# _is_work_week
# Returns 0 (true) if current local time is Monday 06:00 – Friday 18:00.
_is_work_week() {
  python3 -c "
from datetime import datetime
now = datetime.now()
dow = now.weekday()   # 0=Mon ... 6=Sun
h   = now.hour
# Work week: Mon(0) 06:00 to Fri(4) 18:00
if dow == 0 and h < 6:   exit(1)   # Mon before 06:00
if dow == 4 and h >= 18: exit(1)   # Fri 18:00+
if dow in (5, 6):         exit(1)   # Sat, Sun
exit(0)
" 2>/dev/null
  return $?
}

# _epoch_is_work_week <epoch>
# Returns 0 (true) if the given Unix timestamp falls within the work week window.
_epoch_is_work_week() {
  local epoch="$1"
  python3 -c "
from datetime import datetime
try:
  now = datetime.fromtimestamp($epoch)
  dow = now.weekday()   # 0=Mon ... 6=Sun
  h   = now.hour
  if dow == 0 and h < 6:   exit(1)   # Mon before 06:00
  if dow == 4 and h >= 18: exit(1)   # Fri 18:00+
  if dow in (5, 6):         exit(1)   # Sat, Sun
  exit(0)
except Exception:
  exit(1)
" 2>/dev/null
  return $?
}

# _check_5h_capacity <agent> <pct_remaining> <reset_epoch>
# Sleep-only helper: sleeps if a 5h threshold is triggered.
# Logging is handled by check_all_agent_capacity (which has both pct values).
_check_5h_capacity() {
  local agent="$1"
  local pct_remaining="$2"
  local reset_epoch="$3"
  local now wait_secs time_until_reset sleep_secs

  if [ "$pct_remaining" -lt "$CAPACITY_5H_CRIT_PCT" ]; then
    # Critical: wait for full 5h reset (+30s buffer for clock skew)
    now=$(date +%s)
    if [ "${reset_epoch:-0}" -gt "$now" ] 2>/dev/null && [ "${reset_epoch:-0}" -gt 0 ] 2>/dev/null; then
      wait_secs=$((reset_epoch - now + 30))
      _capacity_sleep_with_status_check "$wait_secs" "$agent 5h-critical"
    fi
    # If no reliable epoch (reset_epoch <= 0 or already past), skip sleep — logged by caller

  elif [ "$pct_remaining" -lt "$CAPACITY_5H_WARN_PCT" ]; then
    # Warn: sleep 1/3 of the reset window
    now=$(date +%s)
    time_until_reset=$((${reset_epoch:-0} - now))
    if [ "$time_until_reset" -gt 0 ] && [ "${reset_epoch:-0}" -gt 0 ] 2>/dev/null; then
      sleep_secs=$((time_until_reset / 3))
      _capacity_sleep_with_status_check "$sleep_secs" "$agent 5h-warn"
    fi
    # If window already reset, no sleep needed
  fi
}

# _check_weekly_capacity <agent> <remaining_pct_5h> <remaining_pct_weekly> <reset_epoch>
# Applies weekly limit rules with work-week/weekend awareness.
# Receives remaining_pct_5h so log lines can include both percentages (canonical format).
_check_weekly_capacity() {
  local agent="$1"
  local remaining_pct_5h="$2"
  local remaining_pct_weekly="$3"
  local reset_epoch="$4"
  local is_work reset_in_work fresh_pct

  # Determine work-week context
  if _is_work_week; then
    is_work=true
  else
    is_work=false
  fi

  if [ "${reset_epoch:-0}" -gt 0 ] && _epoch_is_work_week "$reset_epoch"; then
    reset_in_work=true
  else
    reset_in_work=false
  fi

  # Decision matrix
  if [ "$is_work" = false ] && [ "$reset_in_work" = false ]; then
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause (currently weekend, reset in weekend: skipping pause)"
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause (currently weekend, reset in weekend: skipping pause)" >> "$LOG_FILE"

  elif [ "$is_work" = false ] && [ "$reset_in_work" = true ]; then
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause (currently weekend, reset in work-week: skipping pause)"
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause (currently weekend, reset in work-week: skipping pause)" >> "$LOG_FILE"

  elif [ "$is_work" = true ] && [ "$reset_in_work" = false ]; then
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause (weekly reset in weekend: skipping pause)"
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause (weekly reset in weekend: skipping pause)" >> "$LOG_FILE"

  else
    # is_work=true AND reset_in_work=true: active pause loop
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause, checking again in 30s"
    echo "[CAPACITY] $agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — work-week pause, checking again in 30s" >> "$LOG_FILE"

    while true; do
      _capacity_sleep_with_status_check 30 "$agent weekly-pause"

      # Re-fetch fresh capacity data (cache refreshes every 60s; 30s chunks keep it fresh)
      if fetch_${agent}_capacity 2>/dev/null; then
        fresh_pct=$CAPACITY_WEEKLY_REMAINING_PCT
      else
        fresh_pct=$remaining_pct_weekly  # fallback to last known value on fetch failure
      fi

      # Exit conditions: capacity recovered or we've left the work week
      if [ "$fresh_pct" -ge 80 ]; then
        echo "[CAPACITY] $agent weekly=${fresh_pct}% — work-week pause ended (capacity restored)"
        echo "[CAPACITY] $agent weekly=${fresh_pct}% — work-week pause ended (capacity restored)" >> "$LOG_FILE"
        break
      fi

      if ! _is_work_week; then
        echo "[CAPACITY] $agent weekly=${fresh_pct}% — work-week pause ended (left work week)"
        echo "[CAPACITY] $agent weekly=${fresh_pct}% — work-week pause ended (left work week)" >> "$LOG_FILE"
        break
      fi

      echo "[CAPACITY] $agent weekly=${fresh_pct}% — work-week pause, checking again in 30s"
      echo "[CAPACITY] $agent weekly=${fresh_pct}% — work-week pause, checking again in 30s" >> "$LOG_FILE"
    done
  fi
}

# ============================================================================
# PUBLIC API
# ============================================================================

# check_all_agent_capacity — called once per build-mode loop iteration.
# For each registered agent: fetches capacity, logs the result, and applies
# threshold rules (sleeping as needed). Never returns non-zero — failures are
# logged and skipped so Ralph is never blocked by a broken capacity endpoint.
check_all_agent_capacity() {
  local remaining_pct_5h epoch_5h remaining_pct_weekly epoch_weekly
  local now wait_secs time_until_reset sleep_secs

  for _agent in $CAPACITY_AGENTS; do
    # Fetch capacity data — skip agent entirely on any failure
    if ! fetch_${_agent}_capacity 2>/dev/null; then
      continue
    fi

    # Read the four standard variables set by the fetch function
    remaining_pct_5h=$CAPACITY_5H_REMAINING_PCT
    epoch_5h=$CAPACITY_5H_RESET_EPOCH
    remaining_pct_weekly=$CAPACITY_WEEKLY_REMAINING_PCT
    epoch_weekly=$CAPACITY_WEEKLY_RESET_EPOCH

    # Apply 5h threshold rules (log first, then sleep via helper)
    if [ "$remaining_pct_5h" -lt "$CAPACITY_5H_CRIT_PCT" ]; then
      now=$(date +%s)
      if [ "${epoch_5h:-0}" -gt "$now" ] 2>/dev/null && [ "${epoch_5h:-0}" -gt 0 ] 2>/dev/null; then
        wait_secs=$((epoch_5h - now + 30))
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — waiting until 5h reset (${wait_secs}s)"
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — waiting until 5h reset (${wait_secs}s)" >> "$LOG_FILE"
      else
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — 5h critical (no reset epoch, continuing)"
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — 5h critical (no reset epoch, continuing)" >> "$LOG_FILE"
      fi
      _check_5h_capacity "$_agent" "$remaining_pct_5h" "$epoch_5h"

    elif [ "$remaining_pct_5h" -lt "$CAPACITY_5H_WARN_PCT" ]; then
      now=$(date +%s)
      time_until_reset=$((${epoch_5h:-0} - now))
      if [ "$time_until_reset" -gt 0 ] && [ "${epoch_5h:-0}" -gt 0 ] 2>/dev/null; then
        sleep_secs=$((time_until_reset / 3))
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — waiting 1/3 of reset window (${sleep_secs}s)"
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — waiting 1/3 of reset window (${sleep_secs}s)" >> "$LOG_FILE"
        _check_5h_capacity "$_agent" "$remaining_pct_5h" "$epoch_5h"
      else
        # Window already reset — treat as OK
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — OK"
        echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — OK" >> "$LOG_FILE"
      fi

    elif [ "$remaining_pct_weekly" -lt "$CAPACITY_WEEKLY_WARN_PCT" ]; then
      # 5h is fine; weekly is low — weekly function logs its own status
      _check_weekly_capacity "$_agent" "$remaining_pct_5h" "$remaining_pct_weekly" "$epoch_weekly"

    else
      # Both thresholds OK
      echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — OK"
      echo "[CAPACITY] $_agent 5h=${remaining_pct_5h}% weekly=${remaining_pct_weekly}% — OK" >> "$LOG_FILE"
    fi

  done

  return 0
}
