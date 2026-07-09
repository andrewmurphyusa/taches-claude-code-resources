#!/bin/bash
# capacity-claude.sh — Claude-specific capacity fetcher for Ralph Orchestrator
#
# shellcheck disable=SC2034 # the four CAPACITY_* vars are set here in caller
# scope and read by capacity-monitor.sh/orchestrator.sh after sourcing —
# invisible to shellcheck's per-file usage analysis.
#
# Reads the OAuth access token from ~/.claude/.credentials.json using python3,
# calls the Anthropic OAuth usage endpoint, caches the raw JSON response to
# ${RALPH_TMP_DIR:-/tmp}/ralph-usage-cache.json with a 60-second TTL, and populates four standard
# variables:
#   CAPACITY_5H_REMAINING_PCT     — percentage of 5-hour window remaining (0-100)
#   CAPACITY_5H_RESET_EPOCH       — Unix epoch when 5h window resets (-1 if unknown)
#   CAPACITY_WEEKLY_REMAINING_PCT — percentage of 7-day window remaining (0-100)
#   CAPACITY_WEEKLY_RESET_EPOCH   — Unix epoch when weekly window resets (-1 if unknown)
#
# Returns 0 on success, 1 on any failure (missing credentials, curl error, HTTP 401,
# parse error). Designed to be sourced by capacity-monitor.sh, not executed directly.

# ============================================================================
# CONSTANTS
# ============================================================================

CAPACITY_CACHE_FILE="${RALPH_TMP_DIR:-/tmp}/ralph-usage-cache.json"
CAPACITY_CACHE_TTL=60   # seconds
CAPACITY_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
CAPACITY_BETA_HEADER="anthropic-beta: oauth-2025-04-20"

# ============================================================================
# Export the capacity-cache-file name for embedding in python3 snippets
# ============================================================================
export CAPACITY_CACHE_FILE

# ============================================================================
# PUBLIC FUNCTIONS
# ============================================================================

# fetch_claude_capacity — fetches (or returns from cache) the current usage data
# and sets CAPACITY_5H_REMAINING_PCT, CAPACITY_5H_RESET_EPOCH,
# CAPACITY_WEEKLY_REMAINING_PCT, CAPACITY_WEEKLY_RESET_EPOCH in caller scope.
# Returns 0 on success, 1 on any failure.
fetch_claude_capacity() {
  # 1. Preflight: require python3
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[CAPACITY] WARNING: python3 not available — capacity checking skipped"
    return 1
  fi

  # 2. Token extraction via python3
  TOKEN=$(python3 -c "
import json, sys, os
path = os.path.expanduser('~/.claude/.credentials.json')
try:
  d = json.load(open(path))
  print(d['claudeAiOauth']['accessToken'])
except Exception:
  sys.exit(1)
" 2>/dev/null)

  # shellcheck disable=SC2181 # $? here is python3's exit status from the
  # command substitution above, not TOKEN's assignment; no direct-check form fits.
  if [ $? -ne 0 ] || [ -z "$TOKEN" ]; then
    echo "[CAPACITY] No Claude OAuth credentials found — capacity checking skipped"
    return 1
  fi

  # 3. Cache TTL check — use python3 for cross-platform mtime
  MTIME=$(python3 -c "
import os, time
capacity_cache_file = os.getenv('CAPACITY_CACHE_FILE')
print(int(time.time() - os.path.getmtime(capacity_cache_file))) if os.path.exists(capacity_cache_file) else print(9999)
" 2>/dev/null)

  if [ "${MTIME:-9999}" -lt "$CAPACITY_CACHE_TTL" ] 2>/dev/null; then
    CACHE_HIT=true
  else
    CACHE_HIT=false
  fi

  # 4. Fetch from API if cache is stale
  if [ "$CACHE_HIT" = false ]; then
    HTTP_BODY=$(curl -s --max-time 5 -w "\n%{http_code}" \
      -H "Authorization: Bearer $TOKEN" \
      -H "$CAPACITY_BETA_HEADER" \
      -H "Content-Type: application/json" \
      "$CAPACITY_USAGE_URL" 2>/dev/null)
    CURL_EXIT=$?

    HTTP_CODE=$(echo "$HTTP_BODY" | tail -1)
    RESPONSE=$(echo "$HTTP_BODY" | head -n -1)

    # 5. HTTP 401 — token expired
    if [ "$HTTP_CODE" = "401" ]; then
      echo "[CAPACITY] claude — OAuth token expired, run 'claude login' to refresh"
      return 1
    fi

    # 6. Other non-200 or curl failure
    if [ "$CURL_EXIT" -ne 0 ] || [ "$HTTP_CODE" != "200" ]; then
      echo "[CAPACITY] claude — fetch failed (HTTP ${HTTP_CODE:-curl-error})"
      return 1
    fi

    # 7. Write to cache (best-effort — non-fatal on failure)
    echo "$RESPONSE" > "$CAPACITY_CACHE_FILE" 2>/dev/null || true
  fi

  # 8. Parse cached/fresh JSON with python3
  PARSE_RESULT=$(python3 -c "
import json, sys, os
from datetime import datetime, timezone
try:
  d = json.load(open(os.getenv('CAPACITY_CACHE_FILE')))
  fh = d.get('five_hour') or {}
  sd = d.get('seven_day') or {}
  util_5h  = int(fh.get('utilization', 0))
  reset_5h = fh.get('resets_at', '')
  util_7d  = int(sd.get('utilization', 0))
  reset_7d = sd.get('resets_at', '')
  def to_epoch(ts):
    if not ts:
      return -1
    try:
      dt = datetime.fromisoformat(ts)
      return int(dt.astimezone(timezone.utc).timestamp())
    except Exception:
      return -1
  print(util_5h, to_epoch(reset_5h), util_7d, to_epoch(reset_7d))
except Exception as e:
  print('ERROR', str(e), file=sys.stderr)
  sys.exit(1)
" 2>"${RALPH_TMP_DIR:-/tmp}/ralph-capacity-parse-error.txt")

  # shellcheck disable=SC2181 # $? here is python3's exit status from the
  # command substitution above, not PARSE_RESULT's assignment.
  if [ $? -ne 0 ]; then
    echo "[CAPACITY] claude — JSON parse failed"
    return 1
  fi

  # 9. Set the four standard variables in caller scope
  local util_5h reset_5h_epoch util_7d reset_7d_epoch
  read -r util_5h reset_5h_epoch util_7d reset_7d_epoch <<< "$PARSE_RESULT"

  CAPACITY_5H_REMAINING_PCT=$((100 - util_5h))
  CAPACITY_5H_RESET_EPOCH=$reset_5h_epoch
  CAPACITY_WEEKLY_REMAINING_PCT=$((100 - util_7d))
  CAPACITY_WEEKLY_RESET_EPOCH=$reset_7d_epoch

  return 0
}

# invalidate_claude_capacity_cache — removes the cache file to force a fresh fetch.
# Called from orchestrator.sh's USAGE_EXHAUSTED branch before re-fetching.
invalidate_claude_capacity_cache() {
  rm -f "$CAPACITY_CACHE_FILE"
}
