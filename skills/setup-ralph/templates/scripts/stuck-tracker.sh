#!/bin/bash
# Stuck Tracker — shared stuck detection functions
# Sourced by both orchestrator.sh and ralph.sh
#
# Depends on: STUCK_FILE, MAX_STUCK, PLAN_FILE, sed_i() being set by caller

# Global state (initialized by caller or init_stuck_tracker)
LAST_TASK="${LAST_TASK:-}"
STUCK_COUNT="${STUCK_COUNT:-0}"
CURRENT_MODEL_TIER="${CURRENT_MODEL_TIER:-}"

init_stuck_tracker() {
  if [ -f "$STUCK_FILE" ]; then
    # Security: Use safe parsing instead of source (prevents shell injection)
    LAST_TASK=$(grep "^LAST_TASK=" "$STUCK_FILE" 2>/dev/null | cut -d'"' -f2 || echo "")
    STUCK_COUNT=$(grep "^STUCK_COUNT=" "$STUCK_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
    CURRENT_MODEL_TIER=$(grep "^CURRENT_MODEL_TIER=" "$STUCK_FILE" 2>/dev/null | cut -d= -f2 || echo "")
    # Ensure STUCK_COUNT is a number
    [[ "$STUCK_COUNT" =~ ^[0-9]+$ ]] || STUCK_COUNT=0
    # Ensure CURRENT_MODEL_TIER is valid (or empty)
    case "$CURRENT_MODEL_TIER" in
      haiku|sonnet|opus) ;;
      *) CURRENT_MODEL_TIER="" ;;
    esac
  else
    LAST_TASK=""
    STUCK_COUNT=0
    CURRENT_MODEL_TIER=""
  fi
}

update_stuck_tracker() {
  local current_task="$1"
  local model_tier="${2:-}"

  if [ "$current_task" = "$LAST_TASK" ] && [ -n "$current_task" ]; then
    STUCK_COUNT=$((STUCK_COUNT + 1))
  else
    LAST_TASK="$current_task"
    STUCK_COUNT=1
    CURRENT_MODEL_TIER=""
  fi

  # Update tier if provided
  if [ -n "$model_tier" ]; then
    CURRENT_MODEL_TIER="$model_tier"
  fi

  echo "LAST_TASK=\"$LAST_TASK\"" > "$STUCK_FILE"
  echo "STUCK_COUNT=$STUCK_COUNT" >> "$STUCK_FILE"
  echo "CURRENT_MODEL_TIER=$CURRENT_MODEL_TIER" >> "$STUCK_FILE"
}

is_stuck() {
  [ "$STUCK_COUNT" -ge "$MAX_STUCK" ]
}

skip_stuck_task() {
  local task="$1"
  echo ""
  echo "STUCK: Failed $MAX_STUCK times on: $task"
  echo "Marking as blocked and moving on..."

  # Add to blockers section or create it
  # Note: We append to end instead of inserting after header (simpler, more portable)
  if ! grep -q "^## Blocked" "$PLAN_FILE" 2>/dev/null; then
    # Create Blocked section at end
    echo "" >> "$PLAN_FILE"
    echo "## Blocked" >> "$PLAN_FILE"
    echo "" >> "$PLAN_FILE"
  fi
  echo "- $task (stuck after $MAX_STUCK attempts)" >> "$PLAN_FILE"

  # Mark the task as skipped in place (change [ ] to [S])
  # Escape regex metacharacters in task name for safe substitution
  local escaped_task escaped_replacement
  escaped_task=$(printf '%s\n' "$task" | sed 's/[[\.*^$()+?{|/]/\\&/g')
  escaped_replacement=$(printf '%s\n' "$task" | sed 's/[\/&]/\\&/g')
  sed_i "s/- \[ \] ${escaped_task}/- [S] $escaped_replacement/" "$PLAN_FILE"

  # Reset stuck counter and model tier
  LAST_TASK=""
  STUCK_COUNT=0
  CURRENT_MODEL_TIER=""
  echo "LAST_TASK=\"\"" > "$STUCK_FILE"
  echo "STUCK_COUNT=0" >> "$STUCK_FILE"
  echo "CURRENT_MODEL_TIER=" >> "$STUCK_FILE"
}
