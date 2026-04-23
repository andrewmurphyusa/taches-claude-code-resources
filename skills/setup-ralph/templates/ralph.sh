#!/bin/bash
# Ralph Wiggum Loop - Autonomous AI Coding
# Based on Geoffrey Huntley's original technique

set -e  # Exit on error

# Resolve script directory for sourcing helpers
LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cross-platform sed -i wrapper (macOS vs Linux compatibility)
sed_i() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Configuration
MODEL="${RALPH_MODEL:-opus}"
ENGINE="${RALPH_ENGINE:-claude}"
VERBOSE="${RALPH_VERBOSE:-false}"
STATUS_FILE="RALPH_STATUS.txt"

# Accepts Claude tier aliases (haiku|sonnet|opus) or any non-empty provider-qualified
# model ID (e.g. gpt-5.3-codex, gemini-3.1-pro-preview) for non-Claude engines.
validate_model() {
  local model="$1"
  case "$model" in
    haiku|sonnet|opus) return 0 ;;
    "")
      echo "Error: model cannot be empty"
      exit 1
      ;;
    *) return 0 ;;
  esac
}
MAX_STUCK="${RALPH_MAX_STUCK:-3}"  # Max failures on same task before skipping
PLAN_FILE="${RALPH_PLAN_FILE:-IMPLEMENTATION_PLAN.md}"
REPORT_FILE="REPORT.md"
ACCUMULATED_REPORT_FILE="REPORT.accumulated.md"
LOG_FILE="ralph.log"
ACCUMULATED_LOG_FILE="ralph.accumulated.log"
START_TIME=$(date +%s)
BACKUP_ENABLED="${RALPH_BACKUP:-true}"  # Push to remote after each commit
PROJECT_NAME=$(basename "$(pwd)")

# Load OAuth token for headless mode (with security checks)
TOKEN_FILE="$HOME/.claude-oauth-token"
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
  # Security: Check file permissions (should be 600 or more restrictive)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    TOKEN_PERMS=$(stat -f %Lp "$TOKEN_FILE" 2>/dev/null)
  else
    TOKEN_PERMS=$(stat -c %a "$TOKEN_FILE" 2>/dev/null)
  fi

  if [ -n "$TOKEN_PERMS" ]; then
    # Check if group or others have any permissions
    if [ "$((TOKEN_PERMS % 100))" -ne 0 ]; then
      echo "⚠️  Security warning: $TOKEN_FILE has insecure permissions ($TOKEN_PERMS)"
      echo "   Run: chmod 600 $TOKEN_FILE"
      echo ""
    fi
  fi

  export CLAUDE_CODE_OAUTH_TOKEN=$(cat "$TOKEN_FILE")
fi

if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo "⚠️  Warning: No OAuth token found. Headless mode may fail."
  echo "   Run 'claude setup-token' and save to ~/.claude-oauth-token"
  echo "   Then: chmod 600 ~/.claude-oauth-token"
  echo ""
fi

# Parse arguments
MODE="build"

while [[ $# -gt 0 ]]; do
  case $1 in
    plan)
      MODE="plan"
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --model)
      MODEL=$2
      validate_model "$MODEL"
      shift 2
      ;;
    --engine)
      ENGINE="$2"
      shift 2
      ;;
    --plan-file)
      PLAN_FILE="$2"
      shift 2
      ;;
    --plan-file=*)
      PLAN_FILE="${1#--plan-file=}"
      shift
      ;;
    *)
      echo "Usage: $0 [plan] [--verbose] [--model MODEL] [--engine ENGINE] [--plan-file FILE]"
      echo ""
      echo "Examples:"
      echo "  $0                        # Build mode, claude engine"
      echo "  $0 plan                   # Plan mode, one planning pass"
      echo "  $0 --verbose              # Enable verbose logging"
      echo "  $0 --model sonnet         # Use Sonnet instead of Opus"
      echo "  $0 --engine codex         # Use Codex engine"
      echo "  $0 --engine gemini        # Use Gemini engine"
      echo "  $0 --plan-file MY_PLAN.md # Use custom plan file"
      echo ""
      echo "Environment variables:"
      echo "  RALPH_ENGINE=claude|codex|gemini  Default engine (default: claude)"
      echo "  RALPH_MODEL=opus|sonnet|haiku     Default model"
      echo "  RALPH_MAX_STUCK=3                 Max failures before skipping task"
      echo "  RALPH_PLAN_FILE=MY_PLAN.md        Custom plan file (overridden by --plan-file)"
      exit 1
      ;;
  esac
done

# Validate model after all args are parsed (ENGINE may affect what's accepted)
validate_model "$MODEL"

# ============================================================================
# REMOTE BACKUP SETUP
# ============================================================================

setup_remote_backup() {
  if [ "$BACKUP_ENABLED" != "true" ]; then
    echo "Remote backup: disabled (set RALPH_BACKUP=true to enable)"
    return 0
  fi

  # Check if git repo exists
  if [ ! -d ".git" ]; then
    echo "Initializing git repository..."
    git init
    git add -A
    git commit -m "Initial commit" 2>/dev/null || true
  fi

  # Check if remote exists
  if git remote get-url origin &>/dev/null; then
    echo "Remote backup: $(git remote get-url origin)"
    return 0
  fi

  # Check if gh CLI is available and authenticated
  if ! command -v gh &>/dev/null; then
    echo "Warning: gh CLI not found. Remote backup disabled."
    echo "Install: https://cli.github.com/"
    BACKUP_ENABLED="false"
    return 1
  fi

  if ! gh auth status &>/dev/null; then
    echo "Warning: gh CLI not authenticated. Remote backup disabled."
    echo "Run: gh auth login"
    BACKUP_ENABLED="false"
    return 1
  fi

  # Create private backup repo
  local repo_name="${PROJECT_NAME}-ralph-backup"
  echo "Creating private backup repo: $repo_name"

  if gh repo create "$repo_name" --private --source=. --push 2>/dev/null; then
    echo "Remote backup: https://github.com/$(gh api user -q .login)/$repo_name"
    return 0
  else
    echo "Warning: Could not create backup repo. Remote backup disabled."
    BACKUP_ENABLED="false"
    return 1
  fi
}

push_to_backup() {
  if [ "$BACKUP_ENABLED" != "true" ]; then
    return 0
  fi

  # Push to remote (suppress errors, don't fail the run)
  if git push origin HEAD 2>/dev/null; then
    echo "📤 Pushed to remote backup"
  else
    echo "⚠️  Push to remote failed (continuing anyway)"
  fi
}

# ============================================================================
# COMPLETION DETECTION
# ============================================================================

check_all_tasks_complete() {
  if [ ! -f "$PLAN_FILE" ]; then
    return 1  # No plan file, not complete
  fi

  # Count incomplete tasks (lines with "- [ ]")
  local incomplete=$(grep -c '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")

  if [ "$incomplete" -eq 0 ]; then
    # Double-check there are actually completed tasks
    local completed=$(grep -c '^\s*- \[x\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
    if [ "$completed" -gt 0 ]; then
      return 0  # All tasks complete
    fi

    # All remaining tasks are skipped — nothing left to execute
    local skipped=$(grep -c '^\s*- \[S\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
    if [ "$skipped" -gt 0 ]; then
      echo "All remaining tasks are skipped — nothing to execute"
      return 0
    fi

    # All remaining tasks are parent containers [P] — nothing executable left
    local parents=$(grep -c '^\s*- \[P\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
    if [ "$parents" -gt 0 ]; then
      echo "All remaining tasks are parent containers — nothing to execute"
      return 0
    fi
  fi

  return 1  # Still have incomplete tasks
}

get_current_task() {
  if [ ! -f "$PLAN_FILE" ]; then
    echo ""
    return
  fi
  # Get first incomplete task — [P] parent tasks are containers and must not be executed directly
  grep '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null | head -1 | sed 's/.*- \[ \] //' || echo ""
}

# ============================================================================
# STUCK DETECTION (sourced from shared module)
# ============================================================================

STUCK_FILE=".ralph_stuck_tracker"
source "$LOOP_DIR/scripts/stuck-tracker.sh"

# ============================================================================
# CAPACITY MONITORING (Claude throttling)
# ============================================================================

# Optional: orchestrator sources this already, but ralph.sh must also do it
# so throttling works in plan mode and when ralph.sh is run directly.
if [ -f "$LOOP_DIR/scripts/capacity-monitor.sh" ]; then
  source "$LOOP_DIR/scripts/capacity-monitor.sh"
else
  echo "Warning: capacity-monitor.sh not found at $LOOP_DIR/scripts/capacity-monitor.sh"
fi

# ============================================================================
# EXECUTION SUMMARY
# ============================================================================

print_execution_summary() {
  local execution_start="$1"
  local execution_end=$(date +%s)
  local duration=$((execution_end - execution_start))
  local mins=$((duration / 60))
  local secs=$((duration % 60))

  # Get the last commit (if any new one was made)
  local last_commit=$(git log -1 --format="%h %s" 2>/dev/null || echo "")
  local last_commit_time=$(git log -1 --format="%ct" 2>/dev/null || echo "0")

  # Check if commit was made during this execution
  local commit_msg=""
  if [ "$last_commit_time" -ge "$execution_start" ]; then
    commit_msg="$last_commit"
  fi

  # Get files changed in last commit
  local files_new=0
  local files_modified=0
  local new_files=""
  local modified_files=""

  if [ -n "$commit_msg" ]; then
    new_files=$(git diff-tree --no-commit-id --name-status -r HEAD 2>/dev/null | grep "^A" | cut -f2 || echo "")
    modified_files=$(git diff-tree --no-commit-id --name-status -r HEAD 2>/dev/null | grep "^M" | cut -f2 || echo "")
    files_new=$(echo "$new_files" | grep -c . 2>/dev/null || echo "0")
    files_modified=$(echo "$modified_files" | grep -c . 2>/dev/null || echo "0")
  fi

  # Get progress
  local completed=$(grep -c '^\s*- \[x\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  local total_tasks=$(grep -c '^\s*- \[' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  local pct=0
  if [ "$total_tasks" -gt 0 ]; then
    pct=$((completed * 100 / total_tasks))
  fi

  echo ""
  echo "━━━ Execution Complete (${mins}m ${secs}s) ━━━"

  if [ -n "$commit_msg" ]; then
    echo "✅ Commit: $commit_msg"
    echo "📁 Files: +$files_new new, ~$files_modified modified"

    # Show new files
    if [ -n "$new_files" ]; then
      echo "$new_files" | while read -r f; do
        [ -n "$f" ] && echo "   🆕 $f"
      done
    fi

    # Show modified files (limit to 5)
    if [ -n "$modified_files" ]; then
      echo "$modified_files" | head -5 | while read -r f; do
        [ -n "$f" ] && echo "   ✏️  $f"
      done
      local mod_count=$(echo "$modified_files" | wc -l | tr -d ' ')
      if [ "$mod_count" -gt 5 ]; then
        echo "   ... and $((mod_count - 5)) more"
      fi
    fi
  else
    echo "⚠️  No commit this execution"
  fi

  echo "📊 Progress: $completed/$total_tasks tasks ($pct%)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================================
# SUMMARY REPORT
# ============================================================================

generate_report() {
  local end_time=$(date +%s)
  local duration=$((end_time - START_TIME))
  local minutes=$((duration / 60))
  local seconds=$((duration % 60))

  local completed=$(grep -c '^[[:space:]]*- \[x\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  local skipped=$(grep -c '^[[:space:]]*- \[S\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  local parents=$(grep -c '^[[:space:]]*- \[P\]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  local remaining=$(grep -c '^[[:space:]]*- \[ \]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  local total=$((completed + skipped + parents + remaining))


  local commit_count=$(git rev-list --count HEAD 2>/dev/null || echo "0")
  local files_changed=$(git diff --name-only $(git rev-list --max-parents=0 HEAD 2>/dev/null) HEAD 2>/dev/null | wc -l | tr -d ' ' || echo "0")


  if [ -f "$REPORT_FILE" ]; then
    echo "Saving previous report to accumulated report..."
    cat $REPORT_FILE >> $ACCUMULATED_REPORT_FILE
  fi

  cat > "$REPORT_FILE" << EOF
# Ralph Session Report

Generated: $(date '+%Y-%m-%d %H:%M:%S')

## Summary

| Metric | Value |
|--------|-------|
| Duration | ${minutes}m ${seconds}s |
| Tasks Completed | $completed / $total |
| Tasks Skipped (stuck) | $skipped |
| Parent Tasks | $parents |
| Tasks Remaining | $remaining |
| Commits | $commit_count |
| Files Changed | $files_changed |

## Exit Reason

EOF

  case "$1" in
    "complete")
      echo "All tasks completed successfully." >> "$REPORT_FILE"
      ;;
    "interrupted")
      echo "Manually interrupted (Ctrl+C)." >> "$REPORT_FILE"
      ;;
    "error")
      echo "Exited due to error (code $2)." >> "$REPORT_FILE"
      ;;
    *)
      echo "Unknown exit reason." >> "$REPORT_FILE"
      ;;
  esac

  # Add completed tasks
  echo "" >> "$REPORT_FILE"
  echo "## Completed Tasks" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  grep '^\s*- \[x\]' "$PLAN_FILE" 2>/dev/null | sed 's/- \[x\]/- ✓/' >> "$REPORT_FILE" || echo "None" >> "$REPORT_FILE"

  # Add skipped tasks if any (only [S] — tasks stuck and skipped by ralph)
  if [ "$skipped" -gt 0 ]; then
    echo "" >> "$REPORT_FILE"
    echo "## Skipped Tasks (stuck)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    grep '^\s*- \[S\]' "$PLAN_FILE" 2>/dev/null | sed 's/- \[S\]/- ⚠/' >> "$REPORT_FILE"
  fi

  # Add parent container tasks if any (only [P] — container tasks with subtasks)
  if [ "$parents" -gt 0 ]; then
    echo "" >> "$REPORT_FILE"
    echo "## Parent Tasks (containers with subtasks)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    grep '^\s*- \[P\]' "$PLAN_FILE" 2>/dev/null | sed 's/- \[P\]/- 📦/' >> "$REPORT_FILE"
  fi

  # Add remaining tasks if any
  if [ "$remaining" -gt 0 ]; then
    echo "" >> "$REPORT_FILE"
    echo "## Remaining Tasks" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    grep '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null >> "$REPORT_FILE"
  fi

  # Add recent commits
  echo "" >> "$REPORT_FILE"
  echo "## Recent Commits" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
  echo '```' >> "$REPORT_FILE"
  git log --oneline -20 2>/dev/null >> "$REPORT_FILE" || echo "No git history" >> "$REPORT_FILE"
  echo '```' >> "$REPORT_FILE"

  echo ""
  echo "Report saved to $REPORT_FILE"
}

# ============================================================================
# ENGINE INVOCATION FUNCTIONS
# ============================================================================

invoke_claude() {
  if ! command -v claude &>/dev/null; then
    echo "Error: Claude CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
    return 1
  fi
  local claude_args=("--model" "$MODEL" "-p" "--dangerously-skip-permissions" "--output-format" "text")
  [ "$VERBOSE" = "true" ] && claude_args+=("--verbose")
  cat "$PROMPT_TMP" | claude "${claude_args[@]}" 2>&1 | tee -a "$LOG_FILE"
  # PIPESTATUS[1] is claude's exit code in the cat|claude|tee pipeline
  return ${PIPESTATUS[1]}
}

invoke_codex() {
  if ! command -v codex &>/dev/null; then
    echo "Error: Codex CLI not found"
    return 1
  fi
  codex exec --model "$MODEL" --sandbox danger-full-access "$(cat "$PROMPT_TMP")" 2>&1 | tee -a "$LOG_FILE"
  return ${PIPESTATUS[0]}
}

invoke_gemini() {
  if ! command -v gemini &>/dev/null; then
    echo "Error: Gemini CLI not found"
    return 1
  fi
  gemini --model "$MODEL" -p "$(cat "$PROMPT_TMP")" 2>&1 | tee -a "$LOG_FILE"
  return ${PIPESTATUS[0]}
}

# ============================================================================
# CLEANUP ON EXIT
# ============================================================================

cleanup() {
  local exit_reason="$1"
  local exit_code="${2:-0}"

  echo ""
  echo "============================================"

  if [ "$MODE" = "build" ]; then
    generate_report "$exit_reason" "$exit_code"
  fi

  # Clean up stuck tracker and NEXT-TASK.md (skip in orchestrated mode)
  if [ "${RALPH_ORCHESTRATED:-}" != "true" ]; then
    rm -f "$STUCK_FILE"
    rm -f "NEXT-TASK.md"
  fi

  echo "============================================"
}

trap 'cleanup "interrupted"; exit 130' INT
trap 'cleanup "error" "$?"; exit $?' ERR

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Select prompt file based on mode
if [ "$MODE" = "plan" ]; then
  PROMPT_FILE="PROMPT_plan.md"
  echo "Ralph Planning Mode"
else
  PROMPT_FILE="PROMPT_build.md"
  echo "Ralph Building Mode"

  # Verify plan file exists before starting build mode
  if [ ! -f "$PLAN_FILE" ]; then
    echo ""
    echo "Error: $PLAN_FILE not found"
    echo "Run './orchestrator.sh plan' first to generate the implementation plan."
    exit 1
  fi

  init_stuck_tracker
fi

# Check prompt file exists
if [ ! -f "$PROMPT_FILE" ]; then
  echo "Error: $PROMPT_FILE not found"
  echo "Run setup to create prompt files"
  exit 1
fi

# Display configuration
echo "Engine: $ENGINE"
echo "Model: $MODEL"
echo "Prompt: $PROMPT_FILE"
echo "Stuck threshold: $MAX_STUCK failures"
echo "Log file: $LOG_FILE (tail -f to watch)"
echo ""

# Setup remote backup (creates private GitHub repo if needed)
setup_remote_backup
echo ""
echo "Starting..."
echo "---"
echo ""

# Save previous log file contents into Accumulate log file so that we don’t lose previous logs
if [ -f "$LOG_FILE" ] ; then
  cat "$LOG_FILE" >> "$ACCUMULATED_LOG_FILE"
fi

# Initialize log file
echo "=== Ralph Session Started $(date ‘+%Y-%m-%d %H:%M:%S’) ===" > "$LOG_FILE"
echo "Mode: $MODE | Engine: $ENGINE | Model: $MODEL" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Check Claude capacity before running (may sleep if thresholds hit).
# Safe even if capacity-monitor.sh wasn’t sourced (function will be missing).
if command -v check_all_agent_capacity >/dev/null 2>&1; then
  check_all_agent_capacity || true
fi

EXECUTION_START=$(date +%s)
echo "📍 Starting - $(date '+%Y-%m-%d %H:%M:%S')"

# BUILD MODE: Check completion and select task
if [ "$MODE" = "build" ]; then
  if check_all_tasks_complete; then
    echo ""
    echo "ALL TASKS COMPLETE"
    cleanup "complete"
    exit 0
  fi

  # Get current task for stuck detection
  current_task=$(get_current_task)
  update_stuck_tracker "$current_task"

  # Check if stuck; skip and exit so orchestrator can select a fresh task
  if is_stuck; then
    skip_stuck_task "$current_task"
    cleanup "complete"
    exit 0
  fi

  # In standalone mode, communicate selected task to Claude via NEXT-TASK.md
  # (In orchestrated mode, orchestrator already wrote NEXT-TASK.md)
  if [ "${RALPH_ORCHESTRATED:-}" != "true" ]; then
    echo "$current_task" > "NEXT-TASK.md"
  fi

  echo "Current task: $current_task"
fi

# Apply plan-file substitution and invoke the selected engine
# Watch progress: tail -f ralph.log
PROMPT_TMP=$(mktemp /tmp/ralph-prompt-XXXXXX.md)
sed "s|IMPLEMENTATION_PLAN\.md|$PLAN_FILE|g" "$PROMPT_FILE" > "$PROMPT_TMP"

set +e
case "$ENGINE" in
  claude)  invoke_claude  ;;
  codex)   invoke_codex   ;;
  gemini)  invoke_gemini  ;;
  *)
    echo "Error: Unknown engine '$ENGINE'. Allowed: claude, codex, gemini"
    rm -f "$PROMPT_TMP"
    cleanup "error" 1
    exit 1
    ;;
esac
ENGINE_EXIT_CODE=$?
set -e

rm -f "$PROMPT_TMP"
if [ "$ENGINE_EXIT_CODE" -eq 0 ]; then
  if [ "$MODE" = "build" ]; then
    print_execution_summary "$EXECUTION_START"
    push_to_backup
  else
    echo "✓ Execution complete"
  fi
else
  echo ""
  echo "❌ $ENGINE exited with code $ENGINE_EXIT_CODE"
  cleanup "error" "$ENGINE_EXIT_CODE"
  exit $ENGINE_EXIT_CODE
fi

cleanup "complete"
