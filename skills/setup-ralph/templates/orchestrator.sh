#!/bin/bash
# Improved Ralph Orchestrator
# Wraps ralph.sh with dynamic model selection based on task complexity
#
# Usage:
#   ./orchestrator.sh              # Build action, auto-select model per task
#   ./orchestrator.sh plan         # Plan action (uses opus)
#   ./orchestrator.sh decompose   # Decompose complex tasks (uses opus, one-shot)
#   ./orchestrator.sh 10           # Build action, max 10 iterations
#   ./orchestrator.sh --model opus # Force a specific model (disables routing)
#   ./orchestrator.sh --help       # Show usage

set -e

# ============================================================================
# RESOLVE PATHS
# ============================================================================

ORCHESTRATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-platform sed -i wrapper (macOS vs Linux compatibility)
sed_i() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Source helpers
source "$ORCHESTRATOR_DIR/scripts/model-config.sh"
source "$ORCHESTRATOR_DIR/scripts/classify-task.sh"
source "$ORCHESTRATOR_DIR/scripts/error-handler.sh"

# Load optional cloud credentials from auth/*.sh (excluding .example templates)
load_cloud_credentials() {
  local auth_dir="$ORCHESTRATOR_DIR/auth"
  local loaded=0

  if [ ! -d "$auth_dir" ]; then
    return 0
  fi

  for cred_file in "$auth_dir"/*.sh; do
    # Skip if glob didn't match (no .sh files)
    [ -f "$cred_file" ] || continue
    # Skip .example template files
    case "$cred_file" in
      *.example) continue ;;
    esac
    # Source the credential file — never log its contents
    source "$cred_file"
    loaded=$((loaded + 1))
    echo "Loaded credentials: $(basename "$cred_file")"
  done

  if [ "$loaded" -eq 0 ]; then
    echo "No cloud credentials found, skipping"
  fi
}

# Load cloud credentials before any Claude invocations
load_cloud_credentials

# Locate ralph.sh: env var override, or local fork in project root
LOOP_SH="${RALPH_LOOP_SH:-$ORCHESTRATOR_DIR/ralph.sh}"

if [ ! -f "$LOOP_SH" ]; then
  echo "Error: ralph.sh not found at $LOOP_SH"
  echo "Set RALPH_LOOP_SH to the path of your ralph.sh, or place it next to orchestrator.sh"
  exit 1
fi

# ============================================================================
# CONFIGURATION
# ============================================================================

PLAN_FILE="IMPLEMENTATION_PLAN.md"
STATUS_FILE="RALPH_STATUS.txt"
LOG_FILE="ralph.log"
ROUTING_ENABLED=true        # Set to false to pass through to ralph.sh without routing
FORCED_MODEL=""             # If set, overrides routing for all tasks

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

ACTION="build"
LIMIT=""
VERBOSE=""
PASSTHROUGH_ARGS=()

# Capacity threshold overrides (applied via env vars before sourcing capacity-monitor.sh)
OVERRIDE_5HR_THRESHOLD=""
OVERRIDE_WEEKLY_THRESHOLD=""

print_help() {
  echo "Improved Ralph Orchestrator — dynamic model routing for autonomous coding"
  echo ""
  echo "Usage: $0 [plan] [limit] [--model MODEL] [--verbose] [--no-routing] [--help]"
  echo "Usage: $0 [plan|decompose] [limit] [--action ACTION] [--limit N] [--model MODEL] [--verbose] [--no-routing] [--help]"
  echo ""
  echo "Actions:"
  echo "  (default)        Build action — pick tasks, implement, validate, commit"
  echo "  plan             Plan action — generate/update IMPLEMENTATION_PLAN.md"
  echo "  decompose        Decompose complex tasks into tier-annotated subtasks"
  echo ""
  echo "Options:"
  echo "  [number]                          Max iterations (e.g., 10)"
  echo "  --action ACTION                   Set action explicitly (build|plan|decompose)"
  echo "  --limit N                         Max iterations (same as providing a number)"
  echo "  --model MODEL                     Force a model (haiku|sonnet|opus) — disables routing"
  echo "  --verbose                         Enable verbose Claude output"
  echo "  --no-routing                      Disable model routing (use RALPH_MODEL or default)"
  echo "  --5hr-remaining-threshold N       Override 5h WARN threshold (remaining %); triggers pre-sleep when below N"
  echo "  --weekly-remaining-threshold N    Override weekly WARN threshold (remaining %); triggers work-week pause when below N"
  echo "  --help                            Show this help message"
  echo ""
  echo "Model Routing:"
  echo "  The orchestrator reads each task from IMPLEMENTATION_PLAN.md and"
  echo "  classifies it as simple/medium/complex using keyword heuristics:"
  echo "    simple  (rename, format, typo, etc.)      -> haiku"
  echo "    medium  (implement, fix bug, tests, etc.)  -> sonnet"
  echo "    complex (architect, debug, refactor, etc.) -> opus"
  echo ""
  echo "Environment Variables:"
  echo "  RALPH_MODEL          Default model if routing disabled (default: opus)"
  echo "  RALPH_LOOP_SH        Path to ralph.sh (default: ./ralph.sh)"
  echo "  RALPH_MAX_STUCK      Max failures before skipping task (default: 3)"
  echo "  RALPH_VERBOSE        Enable verbose mode (true/false)"
  echo "  RALPH_BACKUP         Enable remote backup (true/false, default: true)"
  echo "  RALPH_ORCHESTRATED   Set by orchestrator — ralph.sh skips stuck file cleanup"
  echo ""
  echo "Examples:"
  echo "  $0                   # Build with auto model selection"
  echo "  $0 plan              # Generate implementation plan"
  echo "  $0 20                # Build action, max 20 iterations"
  echo "  $0 --model sonnet    # Force sonnet for all tasks"
  echo "  $0 plan --model opus # Plan with opus"
  echo "  $0 decompose         # Decompose complex tasks (pre-build step)"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    plan)
      ACTION="plan"
      shift
      ;;
    decompose)
      ACTION="decompose"
      shift
      ;;
    --action)
      # --action build|plan|decompose
      ACTION="$2"
      if [ -z "${ACTION:-}" ]; then
        echo "Error: --action requires a value (build|plan|decompose)"
        exit 1
      fi
      case "$ACTION" in
        build|plan|decompose) ;;
        *)
          echo "Error: Invalid --action '$ACTION' (allowed: build|plan|decompose)"
          exit 1
          ;;
      esac
      shift 2
      ;;
    --action=*)
      ACTION="${1#*=}"
      case "$ACTION" in
        build|plan|decompose) ;;
        *)
          echo "Error: Invalid --action '$ACTION' (allowed: build|plan|decompose)"
          exit 1
          ;;
      esac
      shift
      ;;
    --limit)
      # --limit N
      LIMIT="$2"
      if [ -z "${LIMIT:-}" ] || ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
        echo "Error: --limit requires an integer"
        exit 1
      fi
      shift 2
      ;;
    --limit=*)
      LIMIT="${1#*=}"
      if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
        echo "Error: --limit requires an integer"
        exit 1
      fi
      shift
      ;;
    [0-9]*)
      LIMIT=$1
      shift
      ;;
    --verbose)
      VERBOSE="--verbose"
      shift
      ;;
    --model)
      FORCED_MODEL="$2"
      validate_model "$FORCED_MODEL" || exit 1
      ROUTING_ENABLED=false
      shift 2
      ;;
    --no-routing)
      ROUTING_ENABLED=false
      shift
      ;;
    --5hr-remaining-threshold)
      OVERRIDE_5HR_THRESHOLD="$2"
      if [ -z "${OVERRIDE_5HR_THRESHOLD:-}" ] || ! [[ "$OVERRIDE_5HR_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_5HR_THRESHOLD" -gt 100 ]; then
        echo "Error: --5hr-threshold requires an integer 0-100"
        exit 1
      fi
      shift 2
      ;;
    --5hr-remaining-threshold=*)
      OVERRIDE_5HR_THRESHOLD="${1#*=}"
      if ! [[ "$OVERRIDE_5HR_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_5HR_THRESHOLD" -gt 100 ]; then
        echo "Error: --5hr-threshold requires an integer 0-100"
        exit 1
      fi
      shift
      ;;
    --weekly-remaining-threshold)
      OVERRIDE_WEEKLY_THRESHOLD="$2"
      if [ -z "${OVERRIDE_WEEKLY_THRESHOLD:-}" ] || ! [[ "$OVERRIDE_WEEKLY_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_WEEKLY_THRESHOLD" -gt 100 ]; then
        echo "Error: --weekly-threshold requires an integer 0-100"
        exit 1
      fi
      shift 2
      ;;
    --weekly-remaining-threshold=*)
      OVERRIDE_WEEKLY_THRESHOLD="${1#*=}"
      if ! [[ "$OVERRIDE_WEEKLY_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_WEEKLY_THRESHOLD" -gt 100 ]; then
        echo "Error: --weekly-threshold requires an integer 0-100"
        exit 1
      fi
      shift
      ;;
    --help|-h)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_help
      exit 1
      ;;
  esac
done

# ============================================================================
# CAPACITY MONITOR (source after arg parsing so CLI overrides apply)
# ============================================================================
if [ -n "${OVERRIDE_5HR_THRESHOLD:-}" ]; then
  export CAPACITY_5H_WARN_PCT="$OVERRIDE_5HR_THRESHOLD"
fi
if [ -n "${OVERRIDE_WEEKLY_THRESHOLD:-}" ]; then
  export CAPACITY_WEEKLY_WARN_PCT="$OVERRIDE_WEEKLY_THRESHOLD"
fi

# Load capacity monitoring after overrides are exported
source "$ORCHESTRATOR_DIR/scripts/capacity-monitor.sh"
# ============================================================================
# TASK READING
# ============================================================================

# Get the current (first incomplete) task from the plan file
get_current_task() {
  if [ ! -f "$PLAN_FILE" ]; then
    echo ""
    return
  fi
  grep '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null | head -1 | sed 's/.*- \[ \] //' || echo ""
}

# Check if all tasks are complete
check_all_tasks_complete() {
  if [ ! -f "$PLAN_FILE" ]; then
    return 1
  fi
  local incomplete
  incomplete=$(grep -c '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  if [ "$incomplete" -eq 0 ]; then
    local completed
    completed=$(grep -c '^\s*- \[x\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
    if [ "$completed" -gt 0 ]; then
      return 0
    fi
    # All remaining tasks are skipped — nothing left to execute
    local skipped
    skipped=$(grep -c '^\s*- \[S\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
    if [ "$skipped" -gt 0 ]; then
      echo "All remaining tasks are skipped — nothing to execute"
      return 0
    fi
  fi
  return 1
}

# ============================================================================
# MAIN ORCHESTRATION LOOP
# ============================================================================

# Set status file to RUNNING at startup
echo "RUNNING" > "$STATUS_FILE"

echo "============================================"
echo "  Improved Ralph Orchestrator"
echo "============================================"
echo "Action:    $ACTION"
echo "Routing: $ROUTING_ENABLED"
if [ -n "$FORCED_MODEL" ]; then
  echo "Model:   $FORCED_MODEL (forced)"
fi
if [ -n "$LIMIT" ]; then
  echo "Limit:   $LIMIT iterations"
fi
echo "Loop:    $LOOP_SH"
echo "============================================"
echo ""

# Plan action: always use opus, run ralph.sh directly
if [ "$ACTION" = "plan" ]; then
  PLAN_MODEL="${FORCED_MODEL:-opus}"
  echo "Planning with model: $PLAN_MODEL"
  echo ""

  LOOP_ARGS=("plan")
  [ -n "$LIMIT" ] && LOOP_ARGS+=("$LIMIT")
  LOOP_ARGS+=("--model" "$PLAN_MODEL")
  [ -n "$VERBOSE" ] && LOOP_ARGS+=("$VERBOSE")

  RALPH_MODEL="$PLAN_MODEL" exec bash "$LOOP_SH" "${LOOP_ARGS[@]}"
fi

# Decompose action: one-shot opus analysis to split complex tasks
if [ "$ACTION" = "decompose" ]; then
  DECOMPOSE_MODEL="${FORCED_MODEL:-opus}"
  DECOMPOSE_PROMPT="$ORCHESTRATOR_DIR/PROMPT_decompose.md"

  if [ ! -f "$DECOMPOSE_PROMPT" ]; then
    echo "Error: PROMPT_decompose.md not found at $DECOMPOSE_PROMPT"
    exit 1
  fi

  if [ ! -f "$PLAN_FILE" ]; then
    echo "Error: $PLAN_FILE not found."
    echo "Run '$0 plan' first to generate the implementation plan."
    exit 1
  fi

  echo "Decomposing with model: $DECOMPOSE_MODEL"
  echo ""

  CLAUDE_ARGS=("--model" "$DECOMPOSE_MODEL" "-p" "--dangerously-skip-permissions" "--output-format" "text")
  [ -n "$VERBOSE" ] && CLAUDE_ARGS+=("--verbose")

  cat "$DECOMPOSE_PROMPT" | claude "${CLAUDE_ARGS[@]}" 2>&1
  exit $?
fi

# Build action: iterate with per-task model routing
export RALPH_ORCHESTRATED=true
STUCK_FILE=".ralph_stuck_tracker"
MAX_STUCK="${RALPH_MAX_STUCK:-3}"

# Source stuck tracker functions (shared with ralph.sh)
source "$ORCHESTRATOR_DIR/scripts/stuck-tracker.sh"

# Create temp file for capturing ralph.sh output (error classification)
TEMP_OUTPUT=$(mktemp)

# Clean up stuck tracker, temp file, and error handler state on exit
orchestrator_cleanup() {
  rm -f "$STUCK_FILE"
  rm -f "$TEMP_OUTPUT"
  cleanup_error_handler
}
trap orchestrator_cleanup EXIT

# Initialize stuck tracker before main loop
init_stuck_tracker

ITERATION=0
while true; do
  ITERATION=$((ITERATION + 1))

  # Check for stop signal
  if [ -f "$STATUS_FILE" ] && grep -qiE 'BREAK|INTERRUPT|STOP' "$STATUS_FILE" 2>/dev/null; then
    echo ""
    echo "Stop signal detected in $STATUS_FILE: $(cat "$STATUS_FILE")"
    echo "=== Orchestrator stopped via RALPH_STATUS.txt $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
    exit 0
  fi

  # Check iteration limit
  if [ -n "$LIMIT" ] && [ "$ITERATION" -gt "$LIMIT" ]; then
    echo ""
    echo "Reached iteration limit ($LIMIT)"
    exit 0
  fi

  # Check agent capacity before each iteration (sleeps if thresholds triggered)
  check_all_agent_capacity || true

  # Check if plan exists
  if [ ! -f "$PLAN_FILE" ]; then
    echo "Error: $PLAN_FILE not found."
    echo "Run '$0 plan' first to generate the implementation plan."
    exit 1
  fi

  # Check completion
  if check_all_tasks_complete; then
    echo ""
    echo "ALL TASKS COMPLETE"
    exit 0
  fi

  # Get current task
  current_task=$(get_current_task)
  if [ -z "$current_task" ]; then
    echo ""
    echo "No incomplete tasks found, but completion check failed."
    echo "Check IMPLEMENTATION_PLAN.md for tasks that are all [S] skipped."
    exit 1
  fi

  # Update stuck tracker with current task (model tier persisted after selection below)
  update_stuck_tracker "$current_task"

  # Check if stuck on this task — skip if exceeded max retries
  if is_stuck; then
    skip_stuck_task "$current_task"
    continue
  fi

  # Determine model
  if [ "$ROUTING_ENABLED" = true ]; then
    selected_model=$(classify_task "$current_task")
    clean_task=$(strip_tier_annotation "$current_task")
  else
    selected_model="${FORCED_MODEL:-${RALPH_MODEL:-opus}}"
    clean_task="$current_task"
  fi

  # Tier escalation: if stuck >= 2 on same task, upgrade model one tier
  escalated=""
  if [ "$STUCK_COUNT" -ge 2 ] && [ "$STUCK_COUNT" -lt "$MAX_STUCK" ]; then
    if [ "$selected_model" != "opus" ]; then
      original_model="$selected_model"
      selected_model=$(upgrade_tier "$selected_model")
      escalated=" (escalated from $original_model)"
    fi
  fi

  # Persist the selected model tier in the stuck tracker
  CURRENT_MODEL_TIER="$selected_model"
  echo "LAST_TASK=\"$LAST_TASK\"" > "$STUCK_FILE"
  echo "STUCK_COUNT=$STUCK_COUNT" >> "$STUCK_FILE"
  echo "CURRENT_MODEL_TIER=$CURRENT_MODEL_TIER" >> "$STUCK_FILE"

  echo "---"
  echo "Orchestrator iteration $ITERATION"
  echo "Task:  $clean_task"
  echo "Model: $selected_model$escalated"
  echo "Stuck: $STUCK_COUNT/$MAX_STUCK"
  echo "---"

  # Pre-flight token estimation on the prompt file
  PROMPT_FILE="PROMPT_build.md"
  estimate_prompt_tokens "$PROMPT_FILE" > /dev/null 2>&1 || true
  # Run again capturing output for logging (function prints warning to stdout if over threshold)
  token_estimate=$(estimate_prompt_tokens "$PROMPT_FILE")
  echo "Token estimate: ~$token_estimate (from $PROMPT_FILE)"

  # Build ralph.sh arguments: run exactly 1 iteration
  LOOP_ARGS=("1" "--model" "$selected_model")
  [ -n "$VERBOSE" ] && LOOP_ARGS+=("$VERBOSE")

  # Invoke ralph.sh with the selected model for 1 iteration
  # Capture combined stdout+stderr to temp file for error classification
  export RALPH_MODEL="$selected_model"
  set +e
  bash "$LOOP_SH" "${LOOP_ARGS[@]}" 2>&1 | tee "$TEMP_OUTPUT"
  EXIT_CODE=${PIPESTATUS[0]}
  set -e

  if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    echo "Iteration $ITERATION complete (model: $selected_model)"
    mark_window_start
    reset_error_counters
  else
    error_type=$(classify_error "$TEMP_OUTPUT")
    echo ""
    echo "Loop exited with code $EXIT_CODE on iteration $ITERATION"
    echo "Error classification: $error_type"

    # Dispatch based on error type
    case "$error_type" in
      AUTH_FAILURE)
        echo "Authentication failure — cannot continue."
        exit 1
        ;;
      CONTEXT_TOO_LONG)
        echo "Context too long — skipping task."
        skip_stuck_task "$current_task"
        continue
        ;;
      USAGE_EXHAUSTED)
        echo "Usage window exhausted — fetching fresh capacity data."
        # Invalidate stale cache so next fetch gets server-authoritative reset epoch
        for _exhausted_agent in $CAPACITY_AGENTS; do
          invalidate_${_exhausted_agent}_capacity_cache 2>/dev/null || true
        done
        # Re-fetch fresh capacity to populate CAPACITY_5H_RESET_EPOCH
        check_all_agent_capacity || true
        # Prefer server-authoritative reset epoch over WINDOW_START_FILE estimate
        _now=$(date +%s)
        if [ "${CAPACITY_5H_RESET_EPOCH:-0}" -gt "$_now" ] 2>/dev/null; then
          _wait=$(( CAPACITY_5H_RESET_EPOCH - _now + 30 ))
          echo "Sleeping ${_wait}s until server-reported 5h reset (epoch $CAPACITY_5H_RESET_EPOCH)."
          sleep "$_wait"
        else
          sleep_until_window_resets
        fi
        # Don't increment ITERATION — retry the same task after sleep
        ITERATION=$((ITERATION - 1))
        continue
        ;;
      RATE_LIMIT)
        if handle_rate_limit; then
          # Retry — don't increment ITERATION
          ITERATION=$((ITERATION - 1))
          continue
        else
          # Escalated to window sleep — retry after that
          ITERATION=$((ITERATION - 1))
          continue
        fi
        ;;
      OVERLOADED)
        if handle_overloaded; then
          # Retry — don't increment ITERATION
          ITERATION=$((ITERATION - 1))
          continue
        else
          # Escalated to rate limit treatment — retry after that
          ITERATION=$((ITERATION - 1))
          continue
        fi
        ;;
      *)
        echo "Unknown error — propagating exit code."
        exit $EXIT_CODE
        ;;
    esac
  fi

  echo ""
done
