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
source "$ORCHESTRATOR_DIR/scripts/error-handler.sh"

# >>> RALPH_V2 routing-load
# Ralph v2 lane+tier routing: load the centralized routing config and the
# task-annotation parser. These must come AFTER model-config.sh so that any
# variables set by model-config cannot shadow the conf values.
source "$ORCHESTRATOR_DIR/ralph-routing.conf"
source "$ORCHESTRATOR_DIR/scripts/parse-task.sh"
# <<< RALPH_V2 routing-load

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

# >>> RALPH_V2 multi-engine-removed
# Ralph v2: load_engine_config (per-hostname RALPH_MULTI_ENGINE gate) was removed.
# Engine selection is now deterministic via lane -> engine mapping in
# ralph-routing.conf. At most one fallback engine per task on capacity exhaustion.
# <<< RALPH_V2 multi-engine-removed

# ============================================================================
# PER-ENGINE TOKEN LOADING
# ============================================================================

# load_engine_token <engine>
# Loads the OAuth/API token for the given engine from its dedicated token file.
# Token file defaults (override via RALPH_TOKEN_FILE_<ENGINE> env var):
#   claude  -> ~/.claude-oauth-token  -> CLAUDE_CODE_OAUTH_TOKEN
#   codex   -> ~/.codex-api-token     -> OPENAI_API_KEY
#   gemini  -> ~/.gemini-api-token    -> GEMINI_API_KEY
# Skips silently if the corresponding env var is already set.
load_engine_token() {
  local engine="$1"
  local token_file token_env

  case "$engine" in
    claude)
      token_file="${RALPH_TOKEN_FILE_CLAUDE:-$HOME/.claude-oauth-token}"
      token_env="CLAUDE_CODE_OAUTH_TOKEN"
      ;;
    codex)
      token_file="${RALPH_TOKEN_FILE_CODEX:-$HOME/.codex-api-token}"
      token_env="OPENAI_API_KEY"
      ;;
    gemini)
      token_file="${RALPH_TOKEN_FILE_GEMINI:-$HOME/.gemini-api-token}"
      token_env="GEMINI_API_KEY"
      ;;
    *)
      return 0
      ;;
  esac

  # Skip if already set
  local current_val="${!token_env:-}"
  if [ -n "$current_val" ]; then
    return 0
  fi

  if [ -f "$token_file" ]; then
    # Security: warn on insecure permissions (should be 600 or more restrictive)
    local perms
    if [[ "$OSTYPE" == "darwin"* ]]; then
      perms=$(stat -f %Lp "$token_file" 2>/dev/null)
    else
      perms=$(stat -c %a "$token_file" 2>/dev/null)
    fi
    if [ -n "$perms" ] && [ "$((perms % 100))" -ne 0 ]; then
      echo "⚠️  Security warning: $token_file has insecure permissions ($perms)"
      echo "   Run: chmod 600 $token_file"
    fi
    export "$token_env"="$(cat "$token_file")"
    echo "Loaded $engine token: $token_file -> \$$token_env"
  fi
}

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

PLAN_FILE="${RALPH_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"
STATUS_FILE="RALPH_STATUS.txt"
LOG_FILE="ralph.log"
ACCUMULATED_LOG_FILE="${RALPH_ACCUMULATED_LOG:-ralph.accumulated.log}"

# >>> RALPH_V2 capacity-agents
# Always source all three per-engine capacity scripts so check_engine_capacity()
# can be called for any lane-selected engine or fallback.
export RALPH_CAPACITY_AGENTS="${RALPH_CAPACITY_AGENTS:-claude codex gemini}"
# <<< RALPH_V2 capacity-agents

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

STAGE="build"
LIMIT=""
VERBOSE=""
PASSTHROUGH_ARGS=()
STOP_AFTER_TIME=""   # HH:MM
STOP_AFTER_DATE=""   # YYYY-MM-DD
ARG_PLAN_FILE=""

# Capacity threshold overrides (applied via env vars before sourcing capacity-monitor.sh)
OVERRIDE_5HR_WARN_THRESHOLD=""
OVERRIDE_5HR_CRIT_THRESHOLD=""
OVERRIDE_WEEKLY_WARN_THRESHOLD=""

print_help() {
  echo "Improved Ralph Orchestrator — lane+tier routing for autonomous coding"
  echo ""
  echo "Usage: $0 [plan|decompose] [limit] [--limit N] [--stage STAGE] [--verbose] [--plan-file FILE] [--help]"
  echo "Additional parameters: [--5hr-remaining-warning-threshold N] [--5hr-remaining-critical-threshold N] [--weekly-remaining-warning-threshold N]"
  echo ""
  echo "Stages:"
  echo "  (default)        Build stage — pick tasks, implement, validate, commit"
  echo "  plan             Plan stage — generate/update IMPLEMENTATION_PLAN.md"
  echo "  decompose        Decompose complex tasks into lane+tier-annotated subtasks"
  echo ""
  echo "Options:"
  echo "  [number]                                  Max iterations (e.g., 10)"
  echo "  --stage STAGE                             Set stage explicitly (build|plan|decompose)"
  echo "  --limit N                                 Max iterations (same as providing a number)"
  echo "  --verbose                                 Enable verbose Claude output"
  echo "  --5hr-remaining-warning-threshold N       Override 5h WARN threshold (remaining %); triggers pre-sleep when below N"
  echo "  --5hr-remaining-critical-threshold N       Override 5h CRITICAL threshold (remaining %); triggers pre-sleep when below N"
  echo "  --weekly-remaining-warning-threshold N    Override weekly WARN threshold (remaining %); triggers work-week pause when below N"
  echo "  --plan-file FILE                          Plan file to read/write (default: \$RALPH_PLAN_FILE or IMPLEMENTATION_PLAN.md)"
  echo "  --help                                    Show this help message"
  echo ""
  echo "Lane+Tier Routing (Ralph v2):"
  echo "  Each task in $PLAN_FILE must be annotated:"
  echo "    - [ ] [LANE:BUILD] [TIER:Moderate] description"
  echo "  Supported lanes: ARCH | BUILD | VERIFY | GUI | SCAFFOLD"
  echo "  Supported tiers: Simple | Moderate | Complex"
  echo "  Orchestrator maps LANE -> engine (ralph-routing.conf). ralph.sh resolves"
  echo "  MODEL_\${engine}_\${tier}. At most one fallback engine per task on capacity exhaustion."
  echo ""
  echo "Environment Variables:"
  echo "  RALPH_PLAN_FILE                 Plan file path (default: IMPLEMENTATION_PLAN.md); overridden by --plan-file"
  echo "  RALPH_LOOP_SH                   Path to ralph.sh (default: ./ralph.sh)"
  echo "  RALPH_MAX_STUCK                 Max failures before skipping task (default: 3)"
  echo "  RALPH_VERBOSE                   Enable verbose mode (true/false)"
  echo "  RALPH_BACKUP                    Enable remote backup (true/false, default: true)"
  echo "  RALPH_ORCHESTRATED              Set by orchestrator — ralph.sh skips stuck file cleanup"
  echo "  RALPH_CAPACITY_AGENTS           Space-separated capacity agent list (default: claude codex gemini)"
  echo "  RALPH_PLAN_MAX_ITERATIONS       Max plan iterations before stopping (default: 5)"
  echo "  RALPH_DECOMPOSE_MAX_ITERATIONS  Max decompose iterations before stopping (default: 5)"
  echo "  RALPH_TOKEN_FILE_CLAUDE         Claude token file (default: ~/.claude-oauth-token -> CLAUDE_CODE_OAUTH_TOKEN)"
  echo "  RALPH_TOKEN_FILE_CODEX          Codex token file (default: ~/.codex-api-token -> OPENAI_API_KEY)"
  echo "  RALPH_TOKEN_FILE_GEMINI         Gemini token file (default: ~/.gemini-api-token -> GEMINI_API_KEY)"
  echo ""
  echo "Examples:"
  echo "  $0                   # Build stage — route each task via lane+tier"
  echo "  $0 plan              # Generate implementation plan"
  echo "  $0 20                # Build stage, max 20 iterations"
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
    --plan-file)
      ARG_PLAN_FILE="$2"
      if [ -z "${ARG_PLAN_FILE:-}" ]; then
        echo "Error: --plan-file requires a file path"
        exit 1
      fi
      shift 2
      ;;
    --plan-file=*)
      ARG_PLAN_FILE="${1#*=}"
      if [ -z "${ARG_PLAN_FILE:-}" ]; then
        echo "Error: --plan-file requires a file path"
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

# ---------------------------------------------------------------------------
# Resolve plan file: CLI flag takes highest priority, then RALPH_PLAN_FILE env var,
# then the hard-coded default (already set above via ${RALPH_PLAN_FILE:-...}).
# ---------------------------------------------------------------------------
if [ -n "$ARG_PLAN_FILE" ]; then
  PLAN_FILE="$ARG_PLAN_FILE"
fi

# Export so child ralph.sh invocations in all loops pick it up automatically
export RALPH_PLAN_FILE="$PLAN_FILE"

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
    echo "Stopping at: $(date -r "$STOP_EPOCH" +"%Y-%m-%d %H:%M:%S")"
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

# ============================================================================
# BACKWARD COMPATIBILITY MIGRATION
# ============================================================================

# migrate_legacy_parent_markers
# Detects plans written before the [P] parent status was introduced.
# In legacy plans, decomposed parent tasks were marked [S] even though they
# have child tasks — this caused them to be counted as skipped incorrectly.
# Migration rule: if an [S] line has at least one more-indented child [ ] task,
# it was a parent container, not a true skip — convert it to [P].
migrate_legacy_parent_markers() {
  if [ ! -f "$PLAN_FILE" ]; then
    return
  fi

  local migrated
  migrated=$(python3 - "$PLAN_FILE" <<'PYEOF' 2>/dev/null || echo "0")
import re, sys

plan_file = sys.argv[1]
with open(plan_file, 'r') as f:
    lines = f.readlines()

changed = 0
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r'^(\s*)- \[S\] (.*)$', line)
    if m:
        parent_indent = m.group(1)
        # Look ahead for more-indented child task lines
        j = i + 1
        has_children = False
        while j < len(lines):
            cl = lines[j]
            if cl.strip() == '':
                j += 1
                continue
            child_m = re.match(r'^(\s*)- \[(.)\]', cl)
            if child_m:
                if len(child_m.group(1)) > len(parent_indent):
                    has_children = True
                    break
                else:
                    break
            else:
                if len(cl) > 0 and len(cl) - len(cl.lstrip()) > len(parent_indent):
                    j += 1
                    continue
                break
            j += 1
        if has_children:
            lines[i] = re.sub(r'- \[S\]', '- [P]', line, count=1)
            changed += 1
    i += 1

if changed:
    with open(plan_file, 'w') as f:
        f.writelines(lines)
print(changed)
PYEOF

  if [ "${migrated:-0}" -gt 0 ]; then
    echo "Migration: converted $migrated legacy [S] parent marker(s) to [P] in $PLAN_FILE"
  fi
}

# ============================================================================
# TASK READING
# ============================================================================

# Get the current (first incomplete) task from the plan file.
# [P] parent tasks are skipped — we descend to find the first child [ ] task instead.
get_current_task() {
  if [ ! -f "$PLAN_FILE" ]; then
    echo ""
    return
  fi
  grep '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null | head -1 | sed 's/.*- \[ \] //' || echo ""
}

# After each task completes, check whether any [P] parent tasks now have all children
# done and should be auto-completed (marked [x]).
complete_finished_parents() {
  if [ ! -f "$PLAN_FILE" ]; then
    return
  fi

  # Process each [P] parent line; collect its indented children and see if all are [x]
  python3 - "$PLAN_FILE" <<'PYEOF' 2>/dev/null || true
import re, sys

plan_file = sys.argv[1]
with open(plan_file, 'r') as f:
    lines = f.readlines()

changed = False
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r'^(\s*)- \[P\] (.*)$', line)
    if m:
        parent_indent = m.group(1)
        child_indent = parent_indent + '  '
        # Collect child lines (lines more indented than parent)
        j = i + 1
        children = []
        while j < len(lines):
            cl = lines[j]
            # If line is blank, skip
            if cl.strip() == '':
                j += 1
                continue
            # Stop if indentation goes back to parent level or less (non-blank)
            child_m = re.match(r'^(\s*)- \[(.)\]', cl)
            if child_m:
                if len(child_m.group(1)) <= len(parent_indent):
                    break
                children.append(cl)
            else:
                # Non-task line at deeper indent — still part of this block
                if len(cl) > 0 and cl[0] == ' ' and len(cl) - len(cl.lstrip()) > len(parent_indent):
                    j += 1
                    continue
                break
            j += 1

        if children:
            all_done = all(re.search(r'- \[x\]', c) for c in children)
            if all_done:
                lines[i] = re.sub(r'- \[P\]', '- [x]', line, count=1)
                changed = True
    i += 1

if changed:
    with open(plan_file, 'w') as f:
        f.writelines(lines)
    print("Auto-completed parent task(s) in " + plan_file)
PYEOF
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
    # All remaining tasks are parent containers [P] — nothing executable left
    local parents
    parents=$(grep -c '^\s*- \[P\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
    if [ "$parents" -gt 0 ]; then
      echo "All remaining tasks are parent containers — nothing to execute"
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
echo "  Improved Ralph Orchestrator (v2: lane+tier)"
echo "============================================"
echo "Stage:   $STAGE"
echo "Routing: ralph-routing.conf (lane -> engine; [engine+tier] -> model)"
if [ -n "$LIMIT" ]; then
  echo "Limit:   $LIMIT iterations"
fi
echo "Loop:    $LOOP_SH"
echo "============================================"
echo ""

# Plan stage: uses PLAN_ENGINE_DEFAULT + PLAN_TIER_DEFAULT from ralph-routing.conf
if [ "$STAGE" = "plan" ]; then
  PLAN_ENGINE="${PLAN_ENGINE_DEFAULT:-claude}"
  PLAN_TIER="${PLAN_TIER_DEFAULT:-Moderate}"
  MAX_PLAN_ITERATIONS="${RALPH_PLAN_MAX_ITERATIONS:-5}"
  echo "Planning with engine: $PLAN_ENGINE | tier: $PLAN_TIER (max $MAX_PLAN_ITERATIONS iterations)"
  echo ""

  # Save previous log and initialize fresh log for this plan session
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE" >> "$ACCUMULATED_LOG_FILE"
  fi
  echo "=== Ralph Session Started $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
  echo "Stage: plan | Engine: $PLAN_ENGINE | Tier: $PLAN_TIER" >> "$LOG_FILE"
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
    LOOP_ARGS=("--engine" "$PLAN_ENGINE" "--tier" "$PLAN_TIER" "--stage" "plan")
    [ -n "$VERBOSE" ] && LOOP_ARGS+=("$VERBOSE")

    set +e
    bash "$LOOP_SH" "${LOOP_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE" | tee "$PLAN_TEMP_OUTPUT"
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

    # Check if plan output file was modified (semantic done check)
    PLAN_MTIME_AFTER=""
    if [ -f "$PLAN_FILE" ]; then
      PLAN_MTIME_AFTER=$(stat -c %Y "$PLAN_FILE" 2>/dev/null || stat -f %m "$PLAN_FILE" 2>/dev/null || echo "")
    fi

    if [ -n "$PLAN_MTIME_BEFORE" ] && [ "$PLAN_MTIME_BEFORE" = "$PLAN_MTIME_AFTER" ]; then
      echo "Planning complete — $PLAN_FILE unchanged after iteration $PLAN_ITERATION"
      exit 0
    fi

    echo "Plan iteration $PLAN_ITERATION complete"
    echo ""
  done

  rm -f "$PLAN_TEMP_OUTPUT"
  exit 0
fi

# Decompose stage: uses DECOMPOSE_ENGINE_DEFAULT + DECOMPOSE_TIER_DEFAULT from ralph-routing.conf
if [ "$STAGE" = "decompose" ]; then
  DECOMPOSE_ENGINE="${DECOMPOSE_ENGINE_DEFAULT:-claude}"
  DECOMPOSE_TIER="${DECOMPOSE_TIER_DEFAULT:-Moderate}"
  # Resolve model from [engine + tier] for direct CLI invocation below
  _decompose_var="MODEL_${DECOMPOSE_ENGINE}_${DECOMPOSE_TIER}"
  DECOMPOSE_MODEL="${!_decompose_var:-}"
  if [ -z "$DECOMPOSE_MODEL" ]; then
    echo "Error: ${_decompose_var} is unset in ralph-routing.conf"
    exit 1
  fi
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

  echo "Decomposing with engine: $DECOMPOSE_ENGINE | tier: $DECOMPOSE_TIER | model: $DECOMPOSE_MODEL (max $MAX_DECOMPOSE_ITERATIONS iterations)"
  echo ""

  # Save previous log and initialize fresh log for this decompose session
  if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE" >> "$ACCUMULATED_LOG_FILE"
  fi
  echo "=== Ralph Session Started $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
  echo "Stage: decompose | Engine: $DECOMPOSE_ENGINE | Tier: $DECOMPOSE_TIER | Model: $DECOMPOSE_MODEL" >> "$LOG_FILE"
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

    # Semantic done check: if plan output file unchanged, decomposition is complete
    DECOMPOSE_MTIME_AFTER=""
    if [ -f "$PLAN_FILE" ]; then
      DECOMPOSE_MTIME_AFTER=$(stat -c %Y "$PLAN_FILE" 2>/dev/null || stat -f %m "$PLAN_FILE" 2>/dev/null || echo "")
    fi

    if [ -n "$DECOMPOSE_MTIME_BEFORE" ] && [ "$DECOMPOSE_MTIME_BEFORE" = "$DECOMPOSE_MTIME_AFTER" ]; then
      echo "Decompose complete — $PLAN_FILE unchanged after iteration $DECOMPOSE_ITERATION"
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

# >>> RALPH_V2 invoke-engine
# invoke_engine <engine> <tier> <lane> <stage>
# Delegates a single iteration to ralph.sh under lane+tier routing.
# ralph.sh resolves MODEL_${engine}_${tier} from ralph-routing.conf and
# invokes the selected engine once. Captures combined stdout+stderr to
# TEMP_OUTPUT for error classification. Sets INVOKE_EXIT_CODE.
invoke_engine() {
  local engine="$1"
  local tier="$2"
  local lane="$3"
  local stage="$4"

  # Load per-engine OAuth/API token before dispatch
  load_engine_token "$engine"

  local loop_args=("--engine" "$engine" "--tier" "$tier" "--lane" "$lane" "--stage" "$stage")
  [ -n "$VERBOSE" ] && loop_args+=("$VERBOSE")
  bash "$LOOP_SH" "${loop_args[@]}" 2>&1 | tee "$TEMP_OUTPUT"
  INVOKE_EXIT_CODE=${PIPESTATUS[0]}
}
# <<< RALPH_V2 invoke-engine

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

# Migrate legacy [S] parent markers to [P] (one-time, idempotent)
if [ -f "$PLAN_FILE" ]; then
  migrate_legacy_parent_markers
fi

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

  # Capacity check is now per-selected-engine; it runs AFTER task parsing
  # (see RALPH_V2 task-routing below) so we know which engine to check.

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
    echo "Check $PLAN_FILE for tasks that are all [S] skipped or [P] parent containers."
    exit 1
  fi

  # Check if stuck on this task — skip if exceeded max retries
  # NOTE: update_stuck_tracker is called exclusively in ralph.sh to prevent double-increment
  if is_stuck; then
    skip_stuck_task "$current_task"
    continue
  fi

  # >>> RALPH_V2 task-routing
  # Parse lane+tier annotation from the current task, map lane -> engine,
  # and apply stuck-task tier escalation. Model resolution is deferred to
  # ralph.sh (MODEL_${engine}_${tier} from ralph-routing.conf).
  if ! validate_task_annotation "$current_task"; then
    echo "Skipping malformed task — continuing with next." >&2
    skip_stuck_task "$current_task"
    continue
  fi
  parse_task_annotation "$current_task"

  # Map lane -> engine (with BUILD_ENGINE_DEFAULT fallback if lane mapping unset)
  CURRENT_ENGINE="$(resolve_lane_engine "$TASK_LANE")"
  if [ -z "$CURRENT_ENGINE" ]; then
    CURRENT_ENGINE="${BUILD_ENGINE_DEFAULT:-claude}"
  fi
  FALLBACK_ENGINE="$(resolve_lane_fallback "$TASK_LANE")"

  selected_tier="$TASK_TIER"
  clean_task="$TASK_CLEAN"

  # Tier escalation: if stuck >= 2 on same task (below max), bump one step.
  escalated=""
  if [ "$STUCK_COUNT" -ge 2 ] && [ "$STUCK_COUNT" -lt "$MAX_STUCK" ]; then
    if [ "$selected_tier" != "Complex" ]; then
      original_tier="$selected_tier"
      selected_tier="$(upgrade_tier "$selected_tier")"
      escalated=" (escalated from $original_tier)"
    fi
  fi

  # Persist the selected tier and engine in the stuck tracker
  CURRENT_MODEL_TIER="$selected_tier"
  echo "LAST_TASK=\"$LAST_TASK\"" > "$STUCK_FILE"
  echo "STUCK_COUNT=$STUCK_COUNT" >> "$STUCK_FILE"
  echo "CURRENT_MODEL_TIER=$CURRENT_MODEL_TIER" >> "$STUCK_FILE"
  echo "CURRENT_ENGINE=$CURRENT_ENGINE" >> "$STUCK_FILE"

  # Per-engine capacity check on the selected engine (sleeps if thresholds triggered)
  check_engine_capacity "$CURRENT_ENGINE" || true
  # <<< RALPH_V2 task-routing

  # Communicate selected task to Claude via NEXT-TASK.md
  echo "$clean_task" > "NEXT-TASK.md"

  # >>> RALPH_V2 routing-log
  echo "---"
  echo "Orchestrator iteration $ITERATION"
  echo "Task:   $clean_task"
  echo "Lane:   $TASK_LANE"
  echo "Tier:   $selected_tier$escalated"
  echo "Engine: $CURRENT_ENGINE"
  echo "Stuck:  $STUCK_COUNT/$MAX_STUCK"
  echo "Task: $clean_task" >> "$LOG_FILE"
  echo "Lane: $TASK_LANE | Tier: $selected_tier$escalated | Engine: $CURRENT_ENGINE" >> "$LOG_FILE"
  echo "---"
  # <<< RALPH_V2 routing-log

  # Pre-flight token estimation on the prompt file
  PROMPT_FILE="PROMPT_build.md"
  estimate_prompt_tokens "$PROMPT_FILE" > /dev/null 2>&1 || true
  # Run again capturing output for logging (function prints warning to stdout if over threshold)
  token_estimate=$(estimate_prompt_tokens "$PROMPT_FILE")
  echo "Token estimate: ~$token_estimate (from $PROMPT_FILE)"

  # >>> RALPH_V2 invoke-call
  # Invoke the single selected engine for one iteration; capture combined
  # stdout+stderr for error classification. ralph.sh resolves the model from
  # MODEL_${engine}_${tier} via ralph-routing.conf.
  set +e
  invoke_engine "$CURRENT_ENGINE" "$selected_tier" "$TASK_LANE" "build"
  EXIT_CODE=$INVOKE_EXIT_CODE
  set -e
  # <<< RALPH_V2 invoke-call

  if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    echo "Iteration $ITERATION complete (engine: $CURRENT_ENGINE | tier: $selected_tier)"
    # Auto-complete any [P] parent tasks whose children are all [x]
    complete_finished_parents
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
        # >>> RALPH_V2 fallback
        echo "Usage window exhausted on engine: $CURRENT_ENGINE"

        # Write reset epoch to per-engine estimate file for non-Claude engines
        _now=$(date +%s)
        _default_reset_epoch=$(( _now + 18300 ))   # 5h + 5min buffer fallback
        case "$CURRENT_ENGINE" in
          codex)
            echo "$_default_reset_epoch" > "/tmp/ralph-codex-reset.epoch" 2>/dev/null || true
            ;;
          gemini)
            echo "$_default_reset_epoch" > "/tmp/ralph-gemini-reset.epoch" 2>/dev/null || true
            ;;
        esac

        # Single-fallback: try the lane's fallback engine exactly once (no chaining).
        _fallback_succeeded=false
        if [ -n "$FALLBACK_ENGINE" ] && [ "$FALLBACK_ENGINE" != "$CURRENT_ENGINE" ]; then
          echo "Falling back to engine: $FALLBACK_ENGINE | tier: $selected_tier | lane: $TASK_LANE"
          echo "Falling back to engine: $FALLBACK_ENGINE | tier: $selected_tier | lane: $TASK_LANE" >> "$LOG_FILE"

          set +e
          invoke_engine "$FALLBACK_ENGINE" "$selected_tier" "$TASK_LANE" "build"
          EXIT_CODE=$INVOKE_EXIT_CODE
          set -e

          if [ "$EXIT_CODE" -eq 0 ]; then
            echo ""
            echo "Iteration $ITERATION complete (fallback engine: $FALLBACK_ENGINE | tier: $selected_tier)"
            mark_window_start
            reset_error_counters
            _fallback_succeeded=true
          fi
        fi

        if [ "$_fallback_succeeded" = true ]; then
          echo ""
          continue
        fi

        # No fallback configured, fallback failed, or fallback also exhausted —
        # sleep until the primary engine's window resets (no further engine switches).
        echo "Engine $CURRENT_ENGINE exhausted and fallback unavailable/failed — fetching fresh capacity."
        invalidate_${CURRENT_ENGINE}_capacity_cache 2>/dev/null || true
        check_engine_capacity "$CURRENT_ENGINE" || true

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
        # <<< RALPH_V2 fallback
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
