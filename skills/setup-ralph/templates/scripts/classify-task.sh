#!/bin/bash
# Task complexity classifier for improved-ralph orchestrator
# Classifies tasks from IMPLEMENTATION_PLAN.md into haiku/sonnet/opus tiers
# using keyword heuristics from routing research (004)

# Source model config for tier constants and upgrade_tier()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/model-config.sh"

# ============================================================================
# CLASSIFICATION FUNCTION
# ============================================================================

# classify_task <task_text>
# Outputs: haiku, sonnet, or opus
classify_task() {
  local task="$1"

  # Handle empty/missing task
  if [ -z "$task" ]; then
    echo "$MODEL_DEFAULT"
    return
  fi

  # Lowercase the task for case-insensitive matching
  local task_lower
  task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')

  # Step 0: Check for explicit tier annotation [opus], [sonnet], [haiku]
  case "$task_lower" in
    \[opus\]*)  echo "opus";   return ;;
    \[sonnet\]*) echo "sonnet"; return ;;
    \[haiku\]*) echo "haiku";  return ;;
  esac

  # Step 1: Check for force-opus signals
  # "why" at the start of the task
  case "$task_lower" in
    why\ *|why\ is\ *|why\ does\ *) echo "opus"; return ;;
  esac

  # Check opus keywords using a single pattern match
  # Keywords: architect, architecture, design the/a, system design, investigate,
  # root cause, diagnose, trace the bug, debug, refactor the entire/across,
  # restructure all, migrate, migration, security/performance audit, audit the,
  # evaluate alternatives, compare approaches, trade-off, tradeoff, design pattern,
  # abstraction layer, plan the, break down the, identify all changes needed,
  # analyze, analyse
  if echo "$task_lower" | grep -qE 'architect|architecture|design the |design a |system design|investigate|root cause|diagnose|trace the bug|debug|refactor the entire|refactor across|restructure all|migrate|migration|security audit|performance audit|audit the|evaluate alternatives|compare approaches|trade-off|tradeoff|design pattern|abstraction layer|plan the |break down the|identify all changes needed|analyze|analyse'; then
    echo "opus"
    return
  fi

  # Step 2: Check for haiku-tier signals
  local is_haiku=false
  if echo "$task_lower" | grep -qE 'rename|reformat|fix typo|fix the typo|correct spelling|add comment|add comments|update comment|update docstring|add jsdoc|add docstring|move file|move the file|move to directory|update the string|change the string|update the message|update the label|update changelog|add changelog|bump version|update version|add import|remove unused import|update import path|update config value|change the port|update timeout|indent|whitespace|format'; then
    is_haiku=true
  fi

  if [ "$is_haiku" = true ]; then
    # Check negative constraints — if any present, elevate to sonnet
    if echo "$task_lower" | grep -qE 'ensure|without breaking|while preserving|backward compat'; then
      is_haiku=false
    fi

    # Check task length constraint (< 150 chars for haiku)
    if [ "$is_haiku" = true ] && [ "${#task}" -ge 150 ]; then
      is_haiku=false
    fi

    if [ "$is_haiku" = true ]; then
      echo "haiku"
      return
    fi
  fi

  # Step 3: Default to sonnet
  local tier="$MODEL_DEFAULT"

  # Step 4: Apply structural modifiers (may upgrade tier)
  local upgraded=false

  # Task length > 200 characters: upgrade
  if [ "${#task}" -gt 200 ]; then
    tier=$(upgrade_tier "$tier")
    upgraded=true
  fi

  # 3+ file names mentioned (look for patterns like file.ext or path/file)
  if [ "$upgraded" = false ]; then
    local file_count
    file_count=$(echo "$task" | grep -oE '[a-zA-Z0-9_/.-]+\.[a-zA-Z]{1,5}' | wc -l)
    if [ "$file_count" -ge 3 ]; then
      tier=$(upgrade_tier "$tier")
      upgraded=true
    fi
  fi

  # Risk signals
  if [ "$upgraded" = false ]; then
    if echo "$task_lower" | grep -qE 'without breaking|ensure backward|while preserving|and also'; then
      tier=$(upgrade_tier "$tier")
    fi
  fi

  echo "$tier"
}

# strip_tier_annotation <task_text>
# Removes [tier] prefix from task text
strip_tier_annotation() {
  local task="$1"
  # Remove [opus], [sonnet], or [haiku] prefix (case-insensitive via tr)
  local lower
  lower=$(echo "$task" | cut -c1-8 | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    \[opus\]*)   echo "$task" | sed 's/^\[[oO][pP][uU][sS]\] *//' ;;
    \[sonnet\]*) echo "$task" | sed 's/^\[[sS][oO][nN][nN][eE][tT]\] *//' ;;
    \[haiku\]*)  echo "$task" | sed 's/^\[[hH][aA][iI][kK][uU]\] *//' ;;
    *)           echo "$task" ;;
  esac
}

# should_decompose <task_text>
# Returns 0 if the task is a candidate for decomposition, 1 otherwise.
# Decomposition triggers (spec 06):
#   - Classified as opus AND description > 300 characters
#   - Contains "and" connecting distinct actions of different complexity
#   - Mentions 5+ distinct files or components
should_decompose() {
  local task="$1"

  # Handle empty/missing task
  if [ -z "$task" ]; then
    return 1
  fi

  # Trigger 1: opus-tier AND > 300 chars
  local tier
  tier=$(classify_task "$task")
  if [ "$tier" = "opus" ] && [ "${#task}" -gt 300 ]; then
    return 0
  fi

  # Trigger 2: "and" connecting distinct actions
  # Look for patterns like "verb1 ... and verb2 ..." where verbs suggest different actions
  local task_lower
  task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')
  if echo "$task_lower" | grep -qE '(implement|create|add|write|build|design|fix|update|refactor|migrate|remove|delete) .+ and (implement|create|add|write|build|design|fix|update|refactor|migrate|remove|delete) '; then
    return 0
  fi

  # Trigger 3: 5+ file patterns mentioned
  local file_count
  file_count=$(echo "$task" | grep -oE '[a-zA-Z0-9_/.-]+\.[a-zA-Z]{1,5}' | wc -l)
  file_count=$(echo "$file_count" | tr -d '[:space:]')
  if [ "$file_count" -ge 5 ]; then
    return 0
  fi

  return 1
}
