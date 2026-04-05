#!/bin/bash
# Improved Ralph Orchestrator
# Wraps ralph.sh with dynamic model selection based on task complexity
#
# Usage:
#   ./orchestrator.sh              # Build stage, auto-select model per task
#   ./orchestrator.sh plan         # Plan stage (uses opus)
#   ./orchestrator.sh decompose   # Decompose complex tasks (iterative, uses opus)
#   ./orchestrator.sh 10           # Build stage, max 10 iterations
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

# Load optional per-hostname multi-engine gate from auth/engines-config.json.
# Sets RALPH_MULTI_ENGINE if the current hostname is found in the config.
# Layer precedence: env var → engines-config.json → default (false)
load_engine_config() {
  local config_file="$ORCHESTRATOR_DIR/auth/engines-config.json"
  if [ ! -f "$config_file" ]; then
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "WARNING: python3 not available — engines-config.json not loaded"
    return 0
  fi
  local result
  result=$(python3 -c "
import json, socket, sys
try:
  d = json.load(open('$config_file'))
  hostname = socket.gethostname()
  hosts = d.get('hosts', {})
  if hostname in hosts:
    cfg = hosts[hostname]
  else:
    cfg = d.get('default', {})
  val = cfg.get('RALPH_MULTI_ENGINE')
  if val is not None:
    print(str(val).lower())
  else:
    print('')
except Exception as e:
  print('', file=__import__('sys').stderr)
  sys.exit(0)
" 2>/dev/null)
  if [ -n "$result" ]; then
    export RALPH_MULTI_ENGINE="$result"
    echo "Engine config: RALPH_MULTI_ENGINE=$result (from engines-config.json, hostname=$(hostname))"
  fi
}
load_engine_config

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
ACCUMULATED_LOG_FILE="${RALPH_ACCUMULATED_LOG:-ralph.accumulated.log}"
ROUTING_ENABLED=true        # Set to false to pass through to ralph.sh without routing
FORCED_MODEL=""             # If set, overrides routing for all tasks

# Multi-engine: when RALPH_MULTI_ENGINE=true, classify_task() returns a ranked 3-tuple
# and the orchestrator tries primary → secondary → tertiary on capacity failure.
# RALPH_MULTI_ENGINE is already set by model-config.sh (default false) and may be
# overridden by load_engine_config() above or by the RALPH_MULTI_ENGINE env var.
# Export so classify-task.sh can read it.
export RALPH_MULTI_ENGINE="${RALPH_MULTI_ENGINE:-false}"

# Set RALPH_CAPACITY_AGENTS to match active engines so capacity-monitor.sh sources
# all three capacity scripts. Falls back to "claude" for backward compatibility
# when multi-engine is disabled.
if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ]; then
  export RALPH_CAPACITY_AGENTS="${RALPH_CAPACITY_AGENTS:-claude codex gemini}"
else
  export RALPH_CAPACITY_AGENTS="${RALPH_CAPACITY_AGENTS:-claude}"
fi

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

STAGE="build"
LIMIT=""
VERBOSE=""
PASSTHROUGH_ARGS=()
STOP_AFTER_TIME=""   # HH:MM
STOP_AFTER_DATE=""   # YYYY-MM-DD

# Capacity threshold overrides (applied via env vars before sourcing capacity-monitor.sh)
OVERRIDE_5HR_WARN_THRESHOLD=""
OVERRIDE_5HR_CRIT_THRESHOLD=""
OVERRIDE_WEEKLY_WARN_THRESHOLD=""

print_help() {
  echo "Improved Ralph Orchestrator — dynamic model routing for autonomous coding"
  echo ""
  echo "Usage: $0 [plan] [limit] [--model MODEL] [--verbose] [--no-routing] [--help]"
  echo "Usage: $0 [plan|decompose] [limit] [--limit N] [--stage STAGE] [--model MODEL] [--verbose] [--no-routing] [--help]"
  echo "Additional parameters: [--5hr-remaining-warning-threshold N] [--5hr-remaining-critical-threshold N] [--weekly-remaining-warning-threshold N]"
  echo ""
  echo "Stages:"
  echo "  (default)        Build stage — pick tasks, implement, validate, commit"
  echo "  plan             Plan stage — generate/update IMPLEMENTATION_PLAN.md"
  echo "  decompose        Decompose complex tasks into tier-annotated subtasks"
  echo ""
  echo "Options:"
  echo "  [number]                                  Max iterations (e.g., 10)"
  echo "  --stage STAGE                             Set stage explicitly (build|plan|decompose)"
  echo "  --limit N                                 Max iterations (same as providing a number)"
  echo "  --model MODEL                             Force a model (haiku|sonnet|opus) — disables routing"
  echo "  --verbose                                 Enable verbose Claude output"
  echo "  --no-routing                              Disable model routing (use RALPH_MODEL or default)"
  echo "  --5hr-remaining-warning-threshold N       Override 5h WARN threshold (remaining %); triggers pre-sleep when below N"
  echo "  --5hr-remaining-critical-threshold N       Override 5h CRITICAL threshold (remaining %); triggers pre-sleep when below N"
  echo "  --weekly-remaining-warning-threshold N    Override weekly WARN threshold (remaining %); triggers work-week pause when below N"
  echo "  --help                            Show this help message"
  echo ""
  echo "Model Routing:"
  echo "  The orchestrator reads each task from IMPLEMENTATION_PLAN.md and"
  echo "  classifies it as simple/medium/complex using keyword heuristics:"
  echo "    simple  (rename, format, typo, etc.)      -> haiku"
  echo "    medium  (implement, fix bug, tests, etc.)  -> sonnet"
  echo "    complex (architect, debug, refactor, etc.) -> opus"
  echo ""
  echo "Multi-Engine Routing (requires RALPH_MULTI_ENGINE=true):"
  echo "  When enabled, classify_task() returns a ranked 3-engine list:"
  echo "    '1.claude:opus 2.codex:gpt-5.3-codex 3.gemini:gemini-3.1-pro-preview'"
  echo "  The orchestrator tries primary engine first; falls back to secondary/tertiary"
  echo "  on capacity exhaustion before sleeping."
  echo "  Per-hostname config: auth/engines-config.json (see engines-config.json.example)"
  echo ""
  echo "Environment Variables:"
  echo "  RALPH_MODEL                     Default model if routing disabled (default: opus)"
  echo "  RALPH_LOOP_SH                   Path to ralph.sh (default: ./ralph.sh)"
  echo "  RALPH_MAX_STUCK                 Max failures before skipping task (default: 3)"
  echo "  RALPH_VERBOSE                   Enable verbose mode (true/false)"
  echo "  RALPH_BACKUP                    Enable remote backup (true/false, default: true)"
  echo "  RALPH_ORCHESTRATED              Set by orchestrator — ralph.sh skips stuck file cleanup"
  echo "  RALPH_MULTI_ENGINE              Enable multi-engine routing (true/false, default: false)"
  echo "  RALPH_ENGINES                   Space-separated engine list (default: claude codex gemini)"
  echo "  RALPH_CAPACITY_AGENTS           Space-separated capacity agent list (auto-set from RALPH_MULTI_ENGINE)"
  echo "  RALPH_PLAN_MAX_ITERATIONS       Max plan iterations before stopping (default: 5)"
  echo "  RALPH_DECOMPOSE_MAX_ITERATIONS  Max decompose iterations before stopping (default: 5)"
  echo ""
  echo "Examples:"
  echo "  $0                   # Build with auto model selection"
  echo "  $0 plan              # Generate implementation plan"
  echo "  $0 20                # Build stage, max 20 iterations"
  echo "  $0 --model sonnet    # Force sonnet for all tasks"
  echo "  $0 plan --model opus # Plan with opus"
  echo "  $0 decompose         # Decompose complex tasks (pre-build step)"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    plan)
      STAGE="plan"
      shift
      ;;
    decompose)
      STAGE="decompose"
      shift
      ;;
    --stage)
      # --stage build|plan|decompose
      STAGE="$2"
      if [ -z "${STAGE:-}" ]; then
        echo "Error: --stage requires a value (build|plan|decompose)"
        exit 1
      fi
      case "$STAGE" in
        build|plan|decompose) ;;
        *)
          echo "Error: Invalid --stage '$STAGE' (allowed: build|plan|decompose)"
          exit 1
          ;;
      esac
      shift 2
      ;;
    --stage=*)
      STAGE="${1#*=}"
      case "$STAGE" in
        build|plan|decompose) ;;
        *)
          echo "Error: Invalid --stage '$STAGE' (allowed: build|plan|decompose)"
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
    --5hr-remaining-warning-threshold)
      OVERRIDE_5HR_WARN_THRESHOLD="$2"
      if [ -z "${OVERRIDE_5HR_WARN_THRESHOLD:-}" ] || ! [[ "$OVERRIDE_5HR_WARN_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_5HR_WARN_THRESHOLD" -gt 100 ]; then
        echo "Error: --5hr-remaining-warning-threshold requires an integer 0-100"
        exit 1
      fi
      shift 2
      ;;
    --5hr-remaining-warning-threshold=*)
      OVERRIDE_5HR_WARN_THRESHOLD="${1#*=}"
      if ! [[ "$OVERRIDE_5HR_WARN_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_5HR_WARN_THRESHOLD" -gt 100 ]; then
        echo "Error: --5hr-remaining-warning-threshold requires an integer 0-100"
        exit 1
      fi
      shift
      ;;
    --5hr-remaining-critical-threshold)
      OVERRIDE_5HR_CRIT_THRESHOLD="$2"
      if [ -z "${OVERRIDE_5HR_CRIT_THRESHOLD:-}" ] || ! [[ "$OVERRIDE_5HR_CRIT_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_5HR_CRIT_THRESHOLD" -gt 100 ]; then
        echo "Error: --5hr-remaining-critical-threshold requires an integer 0-100"
        exit 1
      fi
      shift 2
      ;;
    --5hr-remaining-critical-threshold=*)
      OVERRIDE_5HR_CRIT_THRESHOLD="${1#*=}"
      if ! [[ "$OVERRIDE_5HR_CRIT_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_5HR_CRIT_THRESHOLD" -gt 100 ]; then
        echo "Error: --5hr-remaining-critical-threshold requires an integer 0-100"
        exit 1
      fi
      shift
      ;;
    --weekly-remaining-warning-threshold)
      OVERRIDE_WEEKLY_WARN_THRESHOLD="$2"
      if [ -z "${OVERRIDE_WEEKLY_WARN_THRESHOLD:-}" ] || ! [[ "$OVERRIDE_WEEKLY_WARN_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_WEEKLY_WARN_THRESHOLD" -gt 100 ]; then
        echo "Error: --weekly-remaining-warning-threshold requires an integer 0-100"
        exit 1
      fi
      shift 2
      ;;
    --weekly-remaining-warning-threshold=*)
      OVERRIDE_WEEKLY_WARN_THRESHOLD="${1#*=}"
      if ! [[ "$OVERRIDE_WEEKLY_WARN_THRESHOLD" =~ ^[0-9]+$ ]] || [ "$OVERRIDE_WEEKLY_WARN_THRESHOLD" -gt 100 ]; then
        echo "Error: --weekly-remaining-warning-threshold requires an integer 0-100"
        exit 1
      fi
      shift
      ;;
    --stop-after-time)
      STOP_AFTER_TIME="$2"
      if [ -z "${STOP_AFTER_TIME:-}" ] || ! [[ "$STOP_AFTER_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "Error: --stop-after-time requires HH:MM (24h format)"
        exit 1
      fi
      shift 2
      ;;
    --stop-after-time=*)
      STOP_AFTER_TIME="${1#*=}"
      if ! [[ "$STOP_AFTER_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "Error: --stop-after-time requires HH:MM (24h format)"
        exit 1
      fi
      shift
      ;;
    --stop-after-date)
      STOP_AFTER_DATE="$2"
      if [ -z "${STOP_AFTER_DATE:-}" ] || ! [[ "$STOP_AFTER_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Error: --stop-after-date requires YYYY-MM-DD"
        exit 1
      fi
      shift 2
      ;;
    --stop-after-date=*)
      STOP_AFTER_DATE="${1#*=}"
      if ! [[ "$STOP_AFTER_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Error: --stop-after-date requires YYYY-MM-DD"
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

STOP_EPOCH=""

# Compute the Unix epoch for the requested stop time.
# Sets global STOP_EPOCH. Called once after argument parsing.
compute_stop_epoch() {
  local stop_date="$1"   # YYYY-MM-DD or ""
  local stop_time="$2"   # HH:MM or ""
  local is_mac=false
  [[ "$OSTYPE" == "darwin"* ]] && is_mac=true

  if [ -n "$stop_date" ] && [ -n "$stop_time" ]; then
    # Both date and time given
    if $is_mac; then
      STOP_EPOCH=$(date -j -f "%Y-%m-%d %H:%M" "$stop_date $stop_time" +%s)
    else
      STOP_EPOCH=$(date -d "$stop_date $stop_time" +%s)
    fi

  elif [ -n "$stop_date" ]; then
    # Date only → stop at midnight (00:00) of that date
    if $is_mac; then
      STOP_EPOCH=$(date -j -f "%Y-%m-%d" "$stop_date" +%s)
    else
      STOP_EPOCH=$(date -d "$stop_date" +%s)
    fi

  elif [ -n "$stop_time" ]; then
    # Time only → next occurrence (today if still future, else tomorrow)
    local candidate
    if $is_mac; then
      candidate=$(date -j -f "%H:%M" "$stop_time" +%s)
    else
      candidate=$(date -d "$stop_time" +%s)
    fi
    local now
    now=$(date +%s)
    if [ "$candidate" -gt "$now" ]; then
      STOP_EPOCH="$candidate"
    else
      # Use tomorrow
      if $is_mac; then
        STOP_EPOCH=$(date -j -v+1d -f "%H:%M" "$stop_time" +%s)
      else
        STOP_EPOCH=$(date -d "tomorrow $stop_time" +%s)
      fi
    fi
  fi
}

# Compute stop epoch once (no-op if neither flag given)
if [ -n "$STOP_AFTER_TIME" ] || [ -n "$STOP_AFTER_DATE" ]; then
  compute_stop_epoch "$STOP_AFTER_DATE" "$STOP_AFTER_TIME"
  # Display computed stop time (platform-branched for human-readable epoch)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Stopping at: $(date -r "$STOP_EPOCH" '+%Y-%m-%d %H:%M:%S')"
  else
    echo "Stopping at: $(date -d "@$STOP_EPOCH" '+%Y-%m-%d %H:%M:%S')"
  fi
fi

# ============================================================================
# CAPACITY MONITOR (source after arg parsing so CLI overrides apply)
# ============================================================================
if [ -n "${OVERRIDE_5HR_CRIT_THRESHOLD:-}" ]; then
  export CAPACITY_5H_CRIT_PCT="$OVERRIDE_5HR_CRIT_THRESHOLD"
fi
if [ -n "${OVERRIDE_5HR_WARN_THRESHOLD:-}" ]; then
  export CAPACITY_5H_WARN_PCT="$OVERRIDE_5HR_WARN_THRESHOLD"
fi
if [ -n "${OVERRIDE_WEEKLY_WARN_THRESHOLD:-}" ]; then
  export CAPACITY_WEEKLY_WARN_PCT="$OVERRIDE_WEEKLY_WARN_THRESHOLD"
fi

# Load capacity monitoring after overrides are exported
source "$ORCHESTRATOR_DIR/scripts/capacity-monitor.sh"

# debugging
echo "CAPACITY_5H_CRIT_PCT = $CAPACITY_5H_CRIT_PCT"
echo "CAPACITY_5H_WARN_PCT = $CAPACITY_5H_WARN_PCT"
echo "CAPACITY_WEEKLY_WARN_PCT = $CAPACITY_WEEKLY_WARN_PCT"

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
echo "Stage:    $STAGE"
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

# Plan stage: always use opus, iterate with stop conditions
if [ "$STAGE" = "plan" ]; then
  PLAN_MODEL="${FORCED_MODEL:-opus}"
  MAX_PLAN_ITERATIONS="${RALPH_PLAN_MAX_ITERATIONS:-5}"
  echo "Planning with model: $PLAN_MODEL (max $MAX_PLAN_ITERATIONS iterations)"
  echo ""

  # Save previous log and initialize fresh log for this plan session
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE" >> "$ACCUMULATED_LOG_FILE"
  fi
  echo "=== Ralph Session Started $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
  echo "Stage: plan | Model: $PLAN_MODEL" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

  PLAN_ITERATION=0
  PLAN_TEMP_OUTPUT=$(mktemp)
  trap 'rm -f "$PLAN_TEMP_OUTPUT"' EXIT

  while true; do
    PLAN_ITERATION=$((PLAN_ITERATION + 1))

    # Check for stop signal
    if [ -f "$STATUS_FILE" ] && grep -qiE 'BREAK|INTERRUPT|STOP' "$STATUS_FILE" 2>/dev/null; then
      echo "Stop signal detected — exiting plan mode"
      echo "=== Plan stopped via RALPH_STATUS.txt $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
      exit 0
    fi

    # Check iteration limit
    if [ "$PLAN_ITERATION" -gt "$MAX_PLAN_ITERATIONS" ]; then
      echo "Plan mode reached iteration limit ($MAX_PLAN_ITERATIONS)"
      exit 0
    fi

    echo "Plan iteration $PLAN_ITERATION / $MAX_PLAN_ITERATIONS"

    # Snapshot plan file mtime before calling Claude (cross-platform)
    PLAN_MTIME_BEFORE=""
    if [ -f "$PLAN_FILE" ]; then
      PLAN_MTIME_BEFORE=$(stat -c %Y "$PLAN_FILE" 2>/dev/null || stat -f %m "$PLAN_FILE" 2>/dev/null || echo "")
    fi

    # Run ralph.sh for one plan pass (ralph.sh is single-pass by design)
    LOOP_ARGS=("plan" "--model" "$PLAN_MODEL")
    [ -n "$VERBOSE" ] && LOOP_ARGS+=("$VERBOSE")

    set +e
    RALPH_MODEL="$PLAN_MODEL" bash "$LOOP_SH" "${LOOP_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" | tee "$PLAN_TEMP_OUTPUT"
    PLAN_EXIT_CODE=${PIPESTATUS[0]}
    set -e

    if [ "$PLAN_EXIT_CODE" -ne 0 ]; then
      error_type=$(classify_error "$PLAN_TEMP_OUTPUT")
      echo "Plan iteration $PLAN_ITERATION failed (exit $PLAN_EXIT_CODE, error: $error_type)"
      case "$error_type" in
        USAGE_EXHAUSTED)
          check_all_agent_capacity || true
          PLAN_ITERATION=$((PLAN_ITERATION - 1))
          continue
          ;;
        RATE_LIMIT)
          handle_rate_limit || true
          PLAN_ITERATION=$((PLAN_ITERATION - 1))
          continue
          ;;
        OVERLOADED)
          handle_overloaded || true
          PLAN_ITERATION=$((PLAN_ITERATION - 1))
          continue
          ;;
        AUTH_FAILURE)
          echo "Authentication failure — cannot continue."
          exit 1
          ;;
        *)
          echo "Plan mode error — propagating exit code."
          exit $PLAN_EXIT_CODE
          ;;
      esac
    fi

    # Check if IMPLEMENTATION_PLAN.md was modified (semantic done check)
    PLAN_MTIME_AFTER=""
    if [ -f "$PLAN_FILE" ]; then
      PLAN_MTIME_AFTER=$(stat -c %Y "$PLAN_FILE" 2>/dev/null || stat -f %m "$PLAN_FILE" 2>/dev/null || echo "")
    fi

    if [ -n "$PLAN_MTIME_BEFORE" ] && [ "$PLAN_MTIME_BEFORE" = "$PLAN_MTIME_AFTER" ]; then
      echo "Planning complete — IMPLEMENTATION_PLAN.md unchanged after iteration $PLAN_ITERATION"
      exit 0
    fi

    echo "Plan iteration $PLAN_ITERATION complete"
    echo ""
  done

  rm -f "$PLAN_TEMP_OUTPUT"
  exit 0
fi

# Decompose stage: iterative opus analysis to split complex tasks
if [ "$STAGE" = "decompose" ]; then
  DECOMPOSE_MODEL="${FORCED_MODEL:-opus}"
  DECOMPOSE_PROMPT="$ORCHESTRATOR_DIR/PROMPT_decompose.md"
  MAX_DECOMPOSE_ITERATIONS="${RALPH_DECOMPOSE_MAX_ITERATIONS:-5}"

  if [ ! -f "$DECOMPOSE_PROMPT" ]; then
    echo "Error: PROMPT_decompose.md not found at $DECOMPOSE_PROMPT"
    exit 1
  fi

  if [ ! -f "$PLAN_FILE" ]; then
    echo "Error: $PLAN_FILE not found."
    echo "Run '$0 plan' first to generate the implementation plan."
    exit 1
  fi

  echo "Decomposing with model: $DECOMPOSE_MODEL (max $MAX_DECOMPOSE_ITERATIONS iterations)"
  echo ""

  # Save previous log and initialize fresh log for this decompose session
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE" >> "$ACCUMULATED_LOG_FILE"
  fi
  echo "=== Ralph Session Started $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
  echo "Stage: decompose | Model: $DECOMPOSE_MODEL" >> "$LOG_FILE"
  echo "" >> "$LOG_FILE"

  DECOMPOSE_ITERATION=0
  DECOMPOSE_TEMP_OUTPUT=$(mktemp)
  trap 'rm -f "$DECOMPOSE_TEMP_OUTPUT"' EXIT

  CLAUDE_ARGS=("--model" "$DECOMPOSE_MODEL" "-p" "--dangerously-skip-permissions" "--output-format" "text")
  [ -n "$VERBOSE" ] && CLAUDE_ARGS+=("--verbose")

  while true; do
    DECOMPOSE_ITERATION=$((DECOMPOSE_ITERATION + 1))

    # Check for stop signal
    if [ -f "$STATUS_FILE" ] && grep -qiE 'BREAK|INTERRUPT|STOP' "$STATUS_FILE" 2>/dev/null; then
      echo "Stop signal detected — exiting decompose mode"
      echo "=== Decompose stopped via RALPH_STATUS.txt $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
      exit 0
    fi

    # Check iteration limit
    if [ "$DECOMPOSE_ITERATION" -gt "$MAX_DECOMPOSE_ITERATIONS" ]; then
      echo "Decompose mode reached iteration limit ($MAX_DECOMPOSE_ITERATIONS)"
      exit 0
    fi

    echo "Decompose iteration $DECOMPOSE_ITERATION / $MAX_DECOMPOSE_ITERATIONS"

    # Snapshot plan file mtime before decompose call (cross-platform)
    DECOMPOSE_MTIME_BEFORE=""
    if [ -f "$PLAN_FILE" ]; then
      DECOMPOSE_MTIME_BEFORE=$(stat -c %Y "$PLAN_FILE" 2>/dev/null || stat -f %m "$PLAN_FILE" 2>/dev/null || echo "")
    fi

    set +e
    cat "$DECOMPOSE_PROMPT" | claude "${CLAUDE_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" | tee "$DECOMPOSE_TEMP_OUTPUT"
    DECOMPOSE_EXIT_CODE=${PIPESTATUS[0]}
    set -e

    if [ "$DECOMPOSE_EXIT_CODE" -ne 0 ]; then
      error_type=$(classify_error "$DECOMPOSE_TEMP_OUTPUT")
      echo "Decompose iteration $DECOMPOSE_ITERATION failed (exit $DECOMPOSE_EXIT_CODE, error: $error_type)"
      case "$error_type" in
        USAGE_EXHAUSTED)
          check_all_agent_capacity || true
          DECOMPOSE_ITERATION=$((DECOMPOSE_ITERATION - 1))
          continue
          ;;
        RATE_LIMIT)
          handle_rate_limit || true
          DECOMPOSE_ITERATION=$((DECOMPOSE_ITERATION - 1))
          continue
          ;;
        OVERLOADED)
          handle_overloaded || true
          DECOMPOSE_ITERATION=$((DECOMPOSE_ITERATION - 1))
          continue
          ;;
        AUTH_FAILURE)
          echo "Authentication failure — cannot continue."
          exit 1
          ;;
        *)
          echo "Decompose mode error — propagating exit code."
          exit $DECOMPOSE_EXIT_CODE
          ;;
      esac
    fi

    # Semantic done check: if IMPLEMENTATION_PLAN.md unchanged, decomposition is complete
    DECOMPOSE_MTIME_AFTER=""
    if [ -f "$PLAN_FILE" ]; then
      DECOMPOSE_MTIME_AFTER=$(stat -c %Y "$PLAN_FILE" 2>/dev/null || stat -f %m "$PLAN_FILE" 2>/dev/null || echo "")
    fi

    if [ -n "$DECOMPOSE_MTIME_BEFORE" ] && [ "$DECOMPOSE_MTIME_BEFORE" = "$DECOMPOSE_MTIME_AFTER" ]; then
      echo "Decompose complete — IMPLEMENTATION_PLAN.md unchanged after iteration $DECOMPOSE_ITERATION"
      echo "=== Decompose session ended $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
      exit 0
    fi

    echo "Decompose iteration $DECOMPOSE_ITERATION complete"
    echo "=== Decompose iteration $DECOMPOSE_ITERATION ended $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
    echo ""
  done

  rm -f "$DECOMPOSE_TEMP_OUTPUT"
  exit 0
fi

# ============================================================================
# MULTI-ENGINE DISPATCH
# ============================================================================

# invoke_engine <engine> <model> <prompt_file>
# Dispatches a single iteration to the appropriate CLI based on the engine name.
# For claude: delegates to ralph.sh (existing path; RALPH_MODEL is set).
# For codex:  calls codex CLI in headless mode.
# For gemini: calls gemini CLI in headless mode via -p flag.
# All engines: captures combined stdout+stderr to TEMP_OUTPUT for error classification.
# Returns the exit code of the invoked process (stored in INVOKE_EXIT_CODE).
invoke_engine() {
  local engine="$1"
  local model="$2"
  local prompt_file="$3"

  case "$engine" in
    claude)
      # Delegate to ralph.sh for one build pass (ralph.sh is single-pass by design)
      export RALPH_MODEL="$model"
      local loop_args=("--model" "$model")
      [ -n "$VERBOSE" ] && loop_args+=("$VERBOSE")
      bash "$LOOP_SH" "${loop_args[@]}" 2>&1 | tee "$TEMP_OUTPUT"
      INVOKE_EXIT_CODE=${PIPESTATUS[0]}
      ;;
    codex)
      # Codex headless: codex exec --model <model> --sandbox danger-full-access "$(cat prompt)"
      # danger-full-access grants codebase read/write access analogous to Claude Code's permissions
      if [ ! -f "$prompt_file" ]; then
        echo "[ENGINE] codex: prompt file '$prompt_file' not found" | tee -a "$TEMP_OUTPUT"
        INVOKE_EXIT_CODE=1
        return 1
      fi
      local codex_prompt
      codex_prompt=$(cat "$prompt_file")
      codex exec --model "$model" --sandbox danger-full-access "$codex_prompt" 2>&1 | tee "$TEMP_OUTPUT"
      INVOKE_EXIT_CODE=${PIPESTATUS[0]}
      ;;
    gemini)
      # Gemini headless: gemini --model <model> -p "$(cat prompt)"
      # The -p flag triggers headless mode automatically (no TTY required)
      if [ ! -f "$prompt_file" ]; then
        echo "[ENGINE] gemini: prompt file '$prompt_file' not found" | tee -a "$TEMP_OUTPUT"
        INVOKE_EXIT_CODE=1
        return 1
      fi
      local gemini_prompt
      gemini_prompt=$(cat "$prompt_file")
      gemini --model "$model" -p "$gemini_prompt" 2>&1 | tee "$TEMP_OUTPUT"
      INVOKE_EXIT_CODE=${PIPESTATUS[0]}
      ;;
    *)
      echo "[ENGINE] Unknown engine '$engine' — cannot dispatch" | tee -a "$TEMP_OUTPUT"
      INVOKE_EXIT_CODE=1
      return 1
      ;;
  esac
}

# Build stage: iterate with per-task model routing
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
  rm -f "NEXT-TASK.md"
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

  # Check wall-clock stop time
  if [ -n "${STOP_EPOCH:-}" ] && [ "$(date +%s)" -ge "$STOP_EPOCH" ]; then
    echo ""
    echo "Wall-clock stop time reached ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo "=== Orchestrator stopped via --stop-after $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
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

  # Determine model / engine priority
  if [ "$ROUTING_ENABLED" = true ]; then
    raw_classification=$(classify_task "$current_task")
    clean_task=$(strip_tier_annotation "$current_task")
  else
    raw_classification="${FORCED_MODEL:-${RALPH_MODEL:-opus}}"
    clean_task="$current_task"
  fi

  # Parse ENGINE_PRIORITY array and select primary engine+model
  CURRENT_ENGINE="claude"
  selected_model="$raw_classification"
  ENGINE_PRIORITY=()
  PROVIDER_INDEX=0

  if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ] && echo "$raw_classification" | grep -qE '^[0-9]+\.[a-z]+:'; then
    # Multi-engine mode: parse ranked 3-tuple into ENGINE_PRIORITY array
    # e.g. "1.claude:opus 2.codex:gpt-5.3-codex 3.gemini:gemini-3.1-pro-preview"
    while IFS= read -r entry; do
      # Each entry: "N.engine:model" — strip the "N." prefix
      entry_no_rank="${entry#*.}"   # "engine:model"
      ENGINE_PRIORITY+=("$entry_no_rank")
    done < <(echo "$raw_classification" | tr ' ' '\n' | grep -E '^[0-9]+\.[a-z]+:')

    if [ "${#ENGINE_PRIORITY[@]}" -gt 0 ]; then
      CURRENT_ENGINE="${ENGINE_PRIORITY[0]%%:*}"
      selected_model="${ENGINE_PRIORITY[0]##*:}"
    fi
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

  # Persist the selected model tier and engine in the stuck tracker
  CURRENT_MODEL_TIER="$selected_model"
  echo "LAST_TASK=\"$LAST_TASK\"" > "$STUCK_FILE"
  echo "STUCK_COUNT=$STUCK_COUNT" >> "$STUCK_FILE"
  echo "CURRENT_MODEL_TIER=$CURRENT_MODEL_TIER" >> "$STUCK_FILE"
  echo "CURRENT_ENGINE=$CURRENT_ENGINE" >> "$STUCK_FILE"

  # Communicate selected task to Claude via NEXT-TASK.md
  echo "$clean_task" > "NEXT-TASK.md"

  echo "---"
  echo "Orchestrator iteration $ITERATION"
  echo "Task:  $clean_task"
  echo "Task: $clean_task" >> "$LOG_FILE"
  if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ]; then
    echo "Engine: $CURRENT_ENGINE | Model: $selected_model$escalated"
    echo "Engine: $CURRENT_ENGINE | Model: $selected_model$escalated" >> "$LOG_FILE"
  else
    echo "Model: $selected_model$escalated"
  fi
  echo "Stuck: $STUCK_COUNT/$MAX_STUCK"
  echo "---"

  # Pre-flight token estimation on the prompt file
  PROMPT_FILE="PROMPT_build.md"
  estimate_prompt_tokens "$PROMPT_FILE" > /dev/null 2>&1 || true
  # Run again capturing output for logging (function prints warning to stdout if over threshold)
  token_estimate=$(estimate_prompt_tokens "$PROMPT_FILE")
  echo "Token estimate: ~$token_estimate (from $PROMPT_FILE)"

  # Invoke engine for 1 iteration; capture combined stdout+stderr for error classification
  set +e
  if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ]; then
    invoke_engine "$CURRENT_ENGINE" "$selected_model" "$PROMPT_FILE"
    EXIT_CODE=$INVOKE_EXIT_CODE
  else
    # Single-engine (Claude-only) path — unchanged
    LOOP_ARGS=("1" "--model" "$selected_model")
    [ -n "$VERBOSE" ] && LOOP_ARGS+=("$VERBOSE")
    export RALPH_MODEL="$selected_model"
    bash "$LOOP_SH" "${LOOP_ARGS[@]}" 2>&1 | tee "$TEMP_OUTPUT"
    EXIT_CODE=${PIPESTATUS[0]}
  fi
  set -e

  if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ]; then
      echo "Iteration $ITERATION complete (engine: ${CURRENT_ENGINE:-claude} | model: $selected_model)"
    else
      echo "Iteration $ITERATION complete (model: $selected_model)"
    fi
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
        echo "Usage window exhausted on engine: ${CURRENT_ENGINE:-claude}"

        # Write reset epoch to per-engine estimate file for non-Claude engines
        # (Gemini epoch-file approach; Codex uses the same file for reactive detection)
        _now=$(date +%s)
        _default_reset_epoch=$(( _now + 18300 ))   # 5h + 5min buffer fallback
        case "${CURRENT_ENGINE:-claude}" in
          codex)
            echo "$_default_reset_epoch" > "/tmp/ralph-codex-reset.epoch" 2>/dev/null || true
            ;;
          gemini)
            echo "$_default_reset_epoch" > "/tmp/ralph-gemini-reset.epoch" 2>/dev/null || true
            ;;
        esac

        # Multi-engine fallback: try secondary/tertiary engine before sleeping
        _provider_fallback=false
        if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ] && [ "${#ENGINE_PRIORITY[@]}" -gt 1 ]; then
          _next_index=$(( PROVIDER_INDEX + 1 ))
          if [ "$_next_index" -lt "${#ENGINE_PRIORITY[@]}" ]; then
            PROVIDER_INDEX=$_next_index
            CURRENT_ENGINE="${ENGINE_PRIORITY[$PROVIDER_INDEX]%%:*}"
            selected_model="${ENGINE_PRIORITY[$PROVIDER_INDEX]##*:}"
            echo "Falling back to engine: $CURRENT_ENGINE | model: $selected_model"
            echo "Falling back to engine: $CURRENT_ENGINE | model: $selected_model" >> "$LOG_FILE"

            # Retry with the fallback engine immediately (same ITERATION)
            set +e
            invoke_engine "$CURRENT_ENGINE" "$selected_model" "$PROMPT_FILE"
            EXIT_CODE=$INVOKE_EXIT_CODE
            set -e

            if [ "$EXIT_CODE" -eq 0 ]; then
              echo ""
              echo "Iteration $ITERATION complete (fallback engine: $CURRENT_ENGINE | model: $selected_model)"
              mark_window_start
              reset_error_counters
              _provider_fallback=true
            else
              # Check if the fallback engine also hit a capacity error
              error_type=$(classify_error "$TEMP_OUTPUT")
              if [ "$error_type" = "USAGE_EXHAUSTED" ]; then
                echo "Fallback engine $CURRENT_ENGINE also exhausted."
                _provider_fallback=false
                # Try tertiary if available
                _next_index2=$(( PROVIDER_INDEX + 1 ))
                if [ "$_next_index2" -lt "${#ENGINE_PRIORITY[@]}" ]; then
                  PROVIDER_INDEX=$_next_index2
                  CURRENT_ENGINE="${ENGINE_PRIORITY[$PROVIDER_INDEX]%%:*}"
                  selected_model="${ENGINE_PRIORITY[$PROVIDER_INDEX]##*:}"
                  echo "Falling back to tertiary engine: $CURRENT_ENGINE | model: $selected_model"
                  echo "Falling back to tertiary engine: $CURRENT_ENGINE | model: $selected_model" >> "$LOG_FILE"

                  set +e
                  invoke_engine "$CURRENT_ENGINE" "$selected_model" "$PROMPT_FILE"
                  EXIT_CODE=$INVOKE_EXIT_CODE
                  set -e

                  if [ "$EXIT_CODE" -eq 0 ]; then
                    echo ""
                    echo "Iteration $ITERATION complete (tertiary engine: $CURRENT_ENGINE | model: $selected_model)"
                    mark_window_start
                    reset_error_counters
                    _provider_fallback=true
                  fi
                fi
              else
                _provider_fallback=false
              fi
            fi
          fi
        fi

        if [ "$_provider_fallback" = true ]; then
          # Fallback succeeded — continue to next iteration
          echo ""
          continue
        fi

        # All providers tried or single-engine mode — sleep until reset
        echo "All available engines exhausted — fetching fresh capacity data."
        # Invalidate stale cache for the original engine so next fetch is fresh
        invalidate_${CURRENT_ENGINE:-claude}_capacity_cache 2>/dev/null || true

        # Re-fetch fresh capacity to populate CAPACITY_5H_RESET_EPOCH
        check_all_agent_capacity || true

        # Use minimum reset epoch across all engines if multi-engine; else Claude's epoch
        if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ]; then
          _min_epoch=$(_compute_min_reset_epoch)
          _now=$(date +%s)
          if [ "${_min_epoch:-0}" -gt "$_now" ] 2>/dev/null && [ "${_min_epoch:-0}" -gt 0 ] 2>/dev/null; then
            _wait=$(( _min_epoch - _now + 30 ))
            echo "Sleeping ${_wait}s until earliest engine reset (epoch ${_min_epoch})."
            sleep "$_wait"
          else
            sleep_until_window_resets
          fi
        else
          # Single-engine path: prefer server-authoritative reset epoch
          _now=$(date +%s)
          if [ "${CAPACITY_5H_RESET_EPOCH:-0}" -gt "$_now" ] 2>/dev/null; then
            _wait=$(( CAPACITY_5H_RESET_EPOCH - _now + 30 ))
            echo "Sleeping ${_wait}s until server-reported 5h reset (epoch $CAPACITY_5H_RESET_EPOCH)."
            sleep "$_wait"
          else
            sleep_until_window_resets
          fi
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
