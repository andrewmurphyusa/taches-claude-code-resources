#!/bin/bash
# Error Classification and Recovery for Ralph Orchestrator
# Classifies ralph.sh output into error types and handles recovery.
# Source this from orchestrator.sh alongside classify-task.sh.
#
# Spec 03 defines 5 error types:
#   USAGE_EXHAUSTED, RATE_LIMIT, OVERLOADED, AUTH_FAILURE, CONTEXT_TOO_LONG
#
# Recovery handlers:
#   mark_window_start / sleep_until_window_resets — 5-hour window tracking
#   handle_rate_limit — exponential backoff 1s-60s with jitter
#   handle_overloaded — fixed 45s sleep, 3 retries

# State files
WINDOW_START_FILE=".ralph_window_start"

# Retry counters (reset on success via reset_error_counters)
RATE_LIMIT_RETRY=0
OVERLOADED_RETRY=0

# classify_error <file_path>
# Greps captured output for known error patterns (priority order).
# Echoes the first match; returns UNKNOWN if no pattern matches.
classify_error() {
  local output_file="$1"

  if [ ! -f "$output_file" ]; then
    echo "UNKNOWN"
    return
  fi

  # Priority order: most specific first
  if grep -qi "usage limit\|5-hour window" "$output_file" 2>/dev/null; then
    echo "USAGE_EXHAUSTED"
  elif grep -qi "rate_limit_error\|429" "$output_file" 2>/dev/null; then
    echo "RATE_LIMIT"
  elif grep -qi "overloaded_error" "$output_file" 2>/dev/null; then
    echo "OVERLOADED"
  elif grep -qi "authentication_error" "$output_file" 2>/dev/null; then
    echo "AUTH_FAILURE"
  elif grep -qi "context_length_exceeded" "$output_file" 2>/dev/null; then
    echo "CONTEXT_TOO_LONG"
  else
    echo "UNKNOWN"
  fi
}

# ============================================================================
# WINDOW TRACKING (5-hour rolling window)
# ============================================================================

# mark_window_start
# Records the current epoch as the start of the 5-hour usage window.
# Called on the first successful iteration (idempotent — won't overwrite).
mark_window_start() {
  if [ ! -f "$WINDOW_START_FILE" ]; then
    date +%s > "$WINDOW_START_FILE"
    echo "Window start recorded at $(date)"
  fi
}

# sleep_until_window_resets
# Reads WINDOW_START from state file, computes remaining time until
# WINDOW_START + 18300 (5h + 5min buffer), and sleeps.
# Returns 0 after sleeping, 1 if no window file exists.
sleep_until_window_resets() {
  if [ ! -f "$WINDOW_START_FILE" ]; then
    echo "No window start recorded — sleeping 5 hours as fallback."
    sleep 18300
    return 0
  fi

  local window_start
  window_start=$(cat "$WINDOW_START_FILE" 2>/dev/null)

  # Validate it's numeric
  if ! [[ "$window_start" =~ ^[0-9]+$ ]]; then
    echo "Invalid window start — sleeping 5 hours as fallback."
    rm -f "$WINDOW_START_FILE"
    sleep 18300
    return 0
  fi

  local now reset_at remaining
  now=$(date +%s)
  reset_at=$((window_start + 18300))
  remaining=$((reset_at - now))

  if [ "$remaining" -le 0 ]; then
    echo "Window has already reset."
    rm -f "$WINDOW_START_FILE"
    return 0
  fi

  echo "Usage window exhausted. Sleeping $remaining seconds (until window resets)."
  sleep "$remaining"
  rm -f "$WINDOW_START_FILE"
  return 0
}

# ============================================================================
# RATE LIMIT BACKOFF (exponential 1s-60s with jitter)
# ============================================================================

# handle_rate_limit
# Exponential backoff: 1s → 2s → 4s → 8s → 16s → 32s → 60s cap.
# Adds ±20% jitter. After 5 consecutive retries, escalates to USAGE_EXHAUSTED.
# Returns 0 to retry, 1 to escalate to window sleep.
handle_rate_limit() {
  RATE_LIMIT_RETRY=$((RATE_LIMIT_RETRY + 1))

  if [ "$RATE_LIMIT_RETRY" -gt 5 ]; then
    echo "Rate limit: exceeded 5 retries — escalating to usage window sleep."
    RATE_LIMIT_RETRY=0
    sleep_until_window_resets
    return 1
  fi

  # Compute base delay: 2^(retry-1), capped at 60
  local base_delay
  base_delay=$((1 << (RATE_LIMIT_RETRY - 1)))
  if [ "$base_delay" -gt 60 ]; then
    base_delay=60
  fi

  # Add ±20% jitter: jitter range = base_delay * 40 / 100
  local jitter_range jitter delay
  jitter_range=$((base_delay * 40 / 100))
  if [ "$jitter_range" -gt 0 ]; then
    jitter=$(( (RANDOM % (jitter_range + 1)) - jitter_range / 2 ))
  else
    jitter=0
  fi
  delay=$((base_delay + jitter))
  if [ "$delay" -lt 1 ]; then
    delay=1
  fi

  echo "Rate limit: retry $RATE_LIMIT_RETRY/5 — sleeping ${delay}s (base: ${base_delay}s)"
  sleep "$delay"
  return 0
}

# ============================================================================
# OVERLOADED RETRY (fixed 45s, 3 attempts)
# ============================================================================

# handle_overloaded
# Fixed 45-second sleep, up to 3 retries.
# After 3 retries, escalates to RATE_LIMIT treatment.
# Returns 0 to retry, 1 to escalate.
handle_overloaded() {
  OVERLOADED_RETRY=$((OVERLOADED_RETRY + 1))

  if [ "$OVERLOADED_RETRY" -gt 3 ]; then
    echo "Overloaded: exceeded 3 retries — escalating to rate limit treatment."
    OVERLOADED_RETRY=0
    handle_rate_limit
    return $?
  fi

  echo "Overloaded: retry $OVERLOADED_RETRY/3 — sleeping 45s"
  sleep 45
  return 0
}

# ============================================================================
# COUNTER MANAGEMENT
# ============================================================================

# reset_error_counters
# Called on successful iteration to reset retry counters.
reset_error_counters() {
  RATE_LIMIT_RETRY=0
  OVERLOADED_RETRY=0
}

# cleanup_error_handler
# Removes state files. Call from orchestrator cleanup trap.
cleanup_error_handler() {
  rm -f "$WINDOW_START_FILE"
}

# ============================================================================
# PRE-FLIGHT TOKEN ESTIMATION
# ============================================================================

# estimate_prompt_tokens <file_path>
# Estimates token count for a prompt file using wc -w × 1.4 multiplier.
# Logs a warning if the estimate exceeds 150,000 tokens.
# Echoes the estimated token count for logging.
# Returns 0 always (warning only — does not abort).
estimate_prompt_tokens() {
  local prompt_file="$1"

  if [ ! -f "$prompt_file" ]; then
    echo "0"
    return 0
  fi

  local word_count estimated_tokens
  word_count=$(wc -w < "$prompt_file" 2>/dev/null || echo "0")
  # Remove leading whitespace (wc -w may produce it on some platforms)
  word_count=$(echo "$word_count" | tr -d '[:space:]')

  # Multiply by 1.4 using integer arithmetic: (words * 14 + 5) / 10
  estimated_tokens=$(( (word_count * 14 + 5) / 10 ))

  if [ "$estimated_tokens" -gt 150000 ]; then
    echo "WARNING: Prompt file '$prompt_file' estimated at ~${estimated_tokens} tokens (${word_count} words × 1.4) — exceeds 150,000 token threshold"
  fi

  echo "$estimated_tokens"
}
