#!/bin/bash
# Ralph Wiggum Loop - Autonomous AI Coding
# Based on Geoffrey Huntley's original technique

set -e  # Exit on error

# Resolve script directory for sourcing helpers
LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify Claude CLI is installed
if ! command -v claude &>/dev/null; then
  echo "Error: Claude CLI not found"
  echo "Install with: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

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
VERBOSE="${RALPH_VERBOSE:-false}"
STATUS_FILE="RALPH_STATUS.txt"

# Validate model against whitelist (security: prevents command injection)
validate_model() {
  local model="$1"
  case "$model" in
    opus|sonnet|haiku) return 0 ;;
    *)
      echo "Error: Invalid model '$model'. Allowed: opus, sonnet, haiku"
      exit 1
      ;;
  esac
}
validate_model "$MODEL"
MAX_STUCK="${RALPH_MAX_STUCK:-3}"  # Max failures on same task before skipping
PLAN_FILE="IMPLEMENTATION_PLAN.md"
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
LIMIT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    plan)
      MODE="plan"
      shift
      ;;
    [0-9]*)
      LIMIT=$1
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
    *)
      echo "Usage: $0 [plan] [limit] [--verbose] [--model opus|sonnet|haiku]"
      echo ""
      echo "Examples:"
      echo "  $0              # Build mode, unlimited (exits when all tasks done)"
      echo "  $0 20           # Build mode, max 20 iterations"
      echo "  $0 plan         # Plan mode, exits when plan is complete"
      echo "  $0 plan 5       # Plan mode, max 5 iterations"
      echo "  $0 --verbose    # Enable verbose logging"
      echo "  $0 --model sonnet  # Use Sonnet instead of Opus"
      echo "  $0 --model haiku   # Use Haiku for simple tasks"
      echo ""
      echo "Environment variables:"
      echo "  RALPH_MODEL=opus|sonnet|haiku    Default model"
      echo "  RALPH_MAX_STUCK=3                Max failures before skipping task"
      exit 1
      ;;
  esac
done

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

  # Push to remote (suppress errors, don't fail the loop)
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
  fi

  return 1  # Still have incomplete tasks
}

get_current_task() {
  if [ ! -f "$PLAN_FILE" ]; then
    echo ""
    return
  fi
  # Get first incomplete task
  grep '^\s*- \[ \]' "$PLAN_FILE" 2>/dev/null | head -1 | sed 's/.*- \[ \] //' || echo ""
}

# ============================================================================
# STUCK DETECTION (sourced from shared module)
# ============================================================================

STUCK_FILE=".ralph_stuck_tracker"
source "$LOOP_DIR/scripts/stuck-tracker.sh"

# ============================================================================
# ITERATION SUMMARY
# ============================================================================

print_iteration_summary() {
  local iteration_start="$1"
  local iteration_end=$(date +%s)
  local duration=$((iteration_end - iteration_start))
  local mins=$((duration / 60))
  local secs=$((duration % 60))

  # Get the last commit (if any new one was made)
  local last_commit=$(git log -1 --format="%h %s" 2>/dev/null || echo "")
  local last_commit_time=$(git log -1 --format="%ct" 2>/dev/null || echo "0")

  # Check if commit was made during this iteration
  local commit_msg=""
  if [ "$last_commit_time" -ge "$iteration_start" ]; then
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
  echo "━━━ Iteration $ITERATION Complete (${mins}m ${secs}s) ━━━"

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
    echo "⚠️  No commit this iteration"
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
  local remaining=$(grep -c '^[[:space:]]*- \[ \]' "$PLAN_FILE" 2>/dev/null; [ $? -le 1 ] || echo "0")
  local total=$((completed + skipped + remaining))


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
| Iterations | $ITERATION |
| Tasks Completed | $completed / $total |
| Tasks Skipped | $skipped |
| Tasks Remaining | $remaining |
| Commits | $commit_count |
| Files Changed | $files_changed |

## Exit Reason

EOF

  case "$1" in
    "complete")
      echo "All tasks completed successfully." >> "$REPORT_FILE"
      ;;
    "limit")
      echo "Reached iteration limit ($LIMIT)." >> "$REPORT_FILE"
      ;;
    "interrupted")
      echo "Manually interrupted (Ctrl+C)." >> "$REPORT_FILE"
      ;;
    "status_file")
      echo "Stopped via RALPH_STATUS.txt signal." >> "$REPORT_FILE"
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

  # Add skipped tasks if any
  if [ "$skipped" -gt 0 ]; then
    echo "" >> "$REPORT_FILE"
    echo "## Skipped Tasks (stuck)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    grep '^\s*- \[S\]' "$PLAN_FILE" 2>/dev/null | sed 's/- \[S\]/- ⚠/' >> "$REPORT_FILE"
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

  # Clean up stuck tracker (skip in orchestrated mode — orchestrator owns the lifecycle)
  if [ "$RALPH_ORCHESTRATED" != "true" ]; then
    rm -f "$STUCK_FILE"
  fi

  echo "============================================"
}

trap 'cleanup "interrupted"; exit 130' INT
trap 'cleanup "error" "$?"; exit $?' ERR

# ============================================================================
# MAIN LOOP
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

# Build Claude CLI command as array (security: avoids eval injection)
CLAUDE_ARGS=("--model" "$MODEL" "-p" "--dangerously-skip-permissions" "--output-format" "text")

if [ "$VERBOSE" = "true" ]; then
  CLAUDE_ARGS+=("--verbose")
fi

# Display configuration
echo "Model: $MODEL"
echo "Claude args: ${CLAUDE_ARGS[*]}"
echo "Prompt: $PROMPT_FILE"
if [ -n "$LIMIT" ]; then
  echo "Limit: $LIMIT iterations"
else
  echo "Limit: until complete (Ctrl+C to stop)"
fi
echo "Stuck threshold: $MAX_STUCK failures"
echo "Log file: $LOG_FILE (tail -f to watch)"
echo ""

# Setup remote backup (creates private GitHub repo if needed)
setup_remote_backup
echo ""
echo "Starting loop..."
echo "---"
echo ""

# Save previous log file contents into Accumulate log file so that we don't lose previous logs
if [ -f "$LOG_FILE" ] ; then
  cat "$LOG_FILE" >> "$ACCUMULATED_LOG_FILE"
fi

# Initialize log file
echo "=== Ralph Session Started $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG_FILE"
echo "Mode: $MODE | Model: $MODEL" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Run the loop
ITERATION=0
while true; do
  ITERATION=$((ITERATION + 1))

  # Check for stop signal
  if [ -f "$STATUS_FILE" ] && grep -qiE 'BREAK|INTERRUPT|STOP' "$STATUS_FILE" 2>/dev/null; then
    echo ""
    echo "Stop signal detected in $STATUS_FILE: $(cat "$STATUS_FILE")"
    echo "=== Ralph stopped via RALPH_STATUS.txt $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
    cleanup "status_file"
    exit 0
  fi

  ITERATION_START=$(date +%s)
  echo "📍 Iteration $ITERATION - $(date '+%Y-%m-%d %H:%M:%S')"

  # BUILD MODE: Check completion before each iteration
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

    # Check if stuck
    if is_stuck; then
      skip_stuck_task "$current_task"
      continue  # Try next iteration with new task
    fi

    echo "Current task: $current_task"
  fi

  # Check iteration limit
  if [ -n "$LIMIT" ] && [ "$ITERATION" -gt "$LIMIT" ]; then
    echo ""
    echo "Reached iteration limit ($LIMIT)"
    cleanup "limit"
    exit 0
  fi

  # Run Claude with prompt (tee to log file for observability)
  # Watch progress: tail -f ralph.log
  if cat "$PROMPT_FILE" | claude "${CLAUDE_ARGS[@]}" 2>&1 | tee -a "$LOG_FILE"; then
    # Print iteration summary in build mode
    if [ "$MODE" = "build" ]; then
      print_iteration_summary "$ITERATION_START"
      # Push to remote backup after each successful iteration
      push_to_backup
    else
      echo "✓ Iteration $ITERATION complete"
    fi
  else
    EXIT_CODE=$?
    echo ""
    echo "❌ Claude exited with code $EXIT_CODE"
    cleanup "error" "$EXIT_CODE"
    exit $EXIT_CODE
  fi

  echo ""

  sleep 1
done
