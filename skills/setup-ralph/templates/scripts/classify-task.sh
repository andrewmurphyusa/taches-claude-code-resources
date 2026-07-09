#!/bin/bash
# Task complexity classifier for improved-ralph orchestrator
# Classifies tasks from IMPLEMENTATION_PLAN.md into haiku/sonnet/opus tiers
# using keyword heuristics from routing research (004)
#
# shellcheck disable=SC2034 # TASK_TYPE_FIT_* rows below are read via
# ${!varname} indirect expansion in score_provider() (fit_var lookup), not by
# literal name — invisible to shellcheck's usage analysis.
#
# Multi-engine mode (RALPH_MULTI_ENGINE=true):
#   classify_task() outputs a ranked 3-tuple:
#     "1.claude:opus 2.codex:gpt-5.3-codex 3.gemini:gemini-3.1-pro-preview"
#   Single-engine mode (RALPH_MULTI_ENGINE=false, default):
#     classify_task() outputs a single tier string: haiku|sonnet|opus

# Source model config for tier constants and upgrade_tier()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091 # SCRIPT_DIR resolved at runtime; see model-config.sh (sibling file)
source "$SCRIPT_DIR/model-config.sh"

# ============================================================================
# TASK TYPE DETECTION
# ============================================================================

# detect_task_type <task_lower>
# Returns one of: arch | impl | review | debug | test | simple
# Uses the same keyword patterns as classify_task() — no new keyword research needed.
detect_task_type() {
  local task_lower="$1"

  # Architecture/planning
  if echo "$task_lower" | grep -qE 'architect|architecture|design the |design a |system design|plan the |break down the|abstraction layer|design pattern'; then
    echo "arch"
    return
  fi

  # Debug/root-cause analysis
  if echo "$task_lower" | grep -qE 'debug|diagnose|root cause|trace the bug|investigate|why '; then
    echo "debug"
    return
  fi

  # Review/evaluation
  if echo "$task_lower" | grep -qE 'review|audit the|evaluate|compare approaches|trade-off|tradeoff|analyze|analyse'; then
    echo "review"
    return
  fi

  # Test writing
  if echo "$task_lower" | grep -qE '\btest\b|\btests\b|\bspec\b|\bassertion\b|\bcoverage\b|\bunit test\b|\bintegration test\b'; then
    echo "test"
    return
  fi

  # Simple edits (haiku-tier signals)
  if echo "$task_lower" | grep -qE 'rename|reformat|fix typo|fix the typo|correct spelling|add comment|add comments|update comment|update docstring|add jsdoc|add docstring|move file|bump version|update version|indent|whitespace|format'; then
    echo "simple"
    return
  fi

  # Default: implementation
  echo "impl"
}

# ============================================================================
# MULTI-ENGINE SUITABILITY SCORING
# ============================================================================
#
# Task-type fit matrix (provider x task_type): values 0-25
# Based on benchmark data and capability research (see research doc 006).
# Rows: claude, codex, gemini
# Cols: arch, impl, review, debug, test, simple
#
# NOTE: bash associative arrays (declare -A) require bash 4.0+.
# macOS ships bash 3.2; using flat variable naming for maximum portability.
TASK_TYPE_FIT_claude_arch=25;   TASK_TYPE_FIT_claude_impl=20;  TASK_TYPE_FIT_claude_review=22
TASK_TYPE_FIT_claude_debug=22;  TASK_TYPE_FIT_claude_test=20;  TASK_TYPE_FIT_claude_simple=15
TASK_TYPE_FIT_codex_arch=15;    TASK_TYPE_FIT_codex_impl=25;   TASK_TYPE_FIT_codex_review=20
TASK_TYPE_FIT_codex_debug=25;   TASK_TYPE_FIT_codex_test=25;   TASK_TYPE_FIT_codex_simple=10
TASK_TYPE_FIT_gemini_arch=22;   TASK_TYPE_FIT_gemini_impl=18;  TASK_TYPE_FIT_gemini_review=25
TASK_TYPE_FIT_gemini_debug=18;  TASK_TYPE_FIT_gemini_test=18;  TASK_TYPE_FIT_gemini_simple=12

# score_provider <engine> <task_type> <tier> <context_est>
# Computes a suitability score (0-100) for the given engine on this task.
# 4 dimensions, each 0-25 points:
#   Dim 1: task-type fit (from TASK_TYPE_FIT matrix above)
#   Dim 2: context window sufficiency (all top-tier models have >=1M; always 25)
#   Dim 3: speed/cost fit (haiku=fast engines score high; opus=heavy=lower speed pts)
#   Dim 4: reliability benchmark proxy (codex=25 SWE-Bench, claude=23, gemini=22)
score_provider() {
  local engine="$1"
  local task_type="$2"
  local tier="$3"
  local context_est="${4:-0}"
  local dim1 dim2 dim3 dim4 total

  # Dim 1: task-type fit — look up flat variable TASK_TYPE_FIT_{engine}_{task_type}
  local fit_var="TASK_TYPE_FIT_${engine}_${task_type}"
  dim1="${!fit_var:-15}"   # default 15 if engine/task_type combination not found

  # Dim 2: context window sufficiency
  # All three providers' opus/sonnet models have >=1M context; haiku models >=128K.
  # For Ralph's typical task prompts this is always sufficient; score 25.
  dim2=25

  # Dim 3: speed/cost fit
  # haiku tasks reward fast/cheap models; opus tasks reward heavy models (speed penalty OK)
  case "$tier" in
    haiku)
      case "$engine" in
        codex)  dim3=25 ;;   # gpt-5.4-mini: >1000 tokens/s
        gemini) dim3=25 ;;   # gemini-3-flash: high throughput
        claude) dim3=20 ;;   # haiku: fast but less optimised than codex/gemini flash
        *)      dim3=15 ;;
      esac
      ;;
    sonnet) dim3=20 ;;        # all mid-range models score equally at sonnet tier
    opus)   dim3=15 ;;        # heavy models; speed penalty acceptable
    *)      dim3=18 ;;
  esac

  # Dim 4: reliability benchmark proxy (SWE-Bench and knowledge-work data)
  case "$engine" in
    codex)  dim4=25 ;;   # gpt-5.3-codex: leading SWE-Bench score
    claude) dim4=23 ;;   # Claude Opus: superior reasoning/prose; 2nd on coding
    gemini) dim4=22 ;;   # gemini-3.1-pro: strong context handling; 3rd on pure coding
    *)      dim4=20 ;;
  esac

  total=$((dim1 + dim2 + dim3 + dim4))
  echo "$total"
}

# classify_task_multi <task>
# Multi-engine variant: scores all engines and returns a ranked annotation string.
# Output: "1.claude:opus 2.codex:gpt-5.3-codex 3.gemini:gemini-3.1-pro-preview"
classify_task_multi() {
  local task="$1"
  local tier task_type context_est

  # Get the complexity tier using the existing single-tier classifier
  tier=$(_classify_task_single "$task")

  # Get the task type category
  local task_lower
  task_lower=$(echo "$task" | tr '[:upper:]' '[:lower:]')
  task_type=$(detect_task_type "$task_lower")

  # Estimate prompt token count (best effort — falls back to 0 on error)
  context_est=$(estimate_prompt_tokens "${PROMPT_FILE:-PROMPT_build.md}" 2>/dev/null || echo "0")

  # Score each engine and collect "score:engine:model" entries
  local entries=()
  local engine model score
  for engine in $ENGINES; do
    model=$(get_model_for_tier "$engine" "$tier")
    score=$(score_provider "$engine" "$task_type" "$tier" "$context_est")
    entries+=("$score:$engine:$model")
  done

  # Sort descending by score (numeric, highest first)
  # shellcheck disable=SC2207 # mapfile/readarray is bash 4+, forbidden by the
  # bash 3.2 (macOS) compatibility requirement; entries never contain
  # whitespace (score:engine:model), so IFS=$'\n' splitting is safe here.
  IFS=$'\n' sorted=($(printf '%s\n' "${entries[@]}" | sort -t: -k1 -rn)); unset IFS

  # Build ranked annotation: "1.engine:model 2.engine:model 3.engine:model"
  local rank=1 annotation=""
  for entry in "${sorted[@]}"; do
    local engine_model="${entry#*:}"    # strips "score:" prefix
    annotation+="${rank}.${engine_model} "
    rank=$((rank + 1))
  done

  # Trim trailing space
  echo "${annotation%% }"
}

# ============================================================================
# SINGLE-TIER CLASSIFICATION (internal + backward-compat public path)
# ============================================================================

# _classify_task_single <task_text>
# Internal function: outputs haiku, sonnet, or opus.
# Extracted from the original classify_task() body for reuse by classify_task_multi().
_classify_task_single() {
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
    why\ *) echo "opus"; return ;;
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

# ============================================================================
# PUBLIC CLASSIFICATION FUNCTION
# ============================================================================

# classify_task <task_text>
# Single-engine mode (RALPH_MULTI_ENGINE=false): outputs haiku|sonnet|opus
# Multi-engine mode (RALPH_MULTI_ENGINE=true):   outputs ranked 3-tuple
#   e.g. "1.claude:opus 2.codex:gpt-5.3-codex 3.gemini:gemini-3.1-pro-preview"
classify_task() {
  local task="$1"

  if [ "${RALPH_MULTI_ENGINE:-false}" = "true" ]; then
    classify_task_multi "$task"
  else
    _classify_task_single "$task"
  fi
}

# ============================================================================
# ANNOTATION UTILITIES
# ============================================================================

# strip_tier_annotation <task_text>
# Removes [tier] prefix OR multi-engine ranked annotation prefix from task text.
# Handles:
#   [opus] foo       → foo
#   [sonnet] foo     → foo
#   [haiku] foo      → foo
#   1.claude:opus 2.codex:gpt-5.3-codex 3.gemini:gemini-3.1-pro-preview    → (empty, annotations only)
#   1.claude:opus foo bar                                                    → (strips all N.engine:model tokens)
strip_tier_annotation() {
  local task="$1"

  # Detect multi-engine ranked format: starts with "N.engine:model"
  # Pattern: one or more "N.word:word " prefixes at start of string
  if echo "$task" | grep -qE '^[0-9]+\.[a-z]+:[a-zA-Z0-9._-]+'; then
    # Strip all leading "N.engine:model " tokens
    echo "$task" | sed 's/^[0-9]*\.[a-z][a-zA-Z0-9_-]*:[a-zA-Z0-9._-][a-zA-Z0-9._-]* *//g' | sed 's/^[[:space:]]*//'
    return
  fi

  # Legacy [tier] format
  local lower
  lower=$(echo "$task" | cut -c1-8 | tr '[:upper:]' '[:lower:]')
  # shellcheck disable=SC2001 # ${var//pattern/replacement} can't express
  # case-insensitive bracket classes like [oO][pP][uU][sS]; sed is clearer here.
  case "$lower" in
    \[opus\]*)   echo "$task" | sed 's/^\[[oO][pP][uU][sS]\] *//' ;;
    \[sonnet\]*) echo "$task" | sed 's/^\[[sS][oO][nN][nN][eE][tT]\] *//' ;;
    \[haiku\]*)  echo "$task" | sed 's/^\[[hH][aA][iI][kK][uU]\] *//' ;;
    *)           echo "$task" ;;
  esac
}

# extract_tier_from_ranked <ranked_annotation>
# Extracts the complexity tier (haiku|sonnet|opus) from a ranked annotation string.
# Used by should_decompose() and stuck-escalation logic when RALPH_MULTI_ENGINE=true.
# The tier is inferred from the primary (first-ranked) engine's model ID.
extract_tier_from_ranked() {
  local annotation="$1"
  # Extract the first entry: e.g. "1.claude:opus" or "1.codex:gpt-5.3-codex"
  local first_entry model_id

  first_entry=$(echo "$annotation" | grep -oE '^[0-9]+\.[a-z]+:[a-zA-Z0-9._-]+' | head -1)
  model_id="${first_entry##*:}"

  # Map model ID to tier
  # shellcheck disable=SC2221,SC2222 # known shadowing: *pro* (opus arm) vs
  # gemini-3.1-pro* (sonnet arm) — pre-existing behavior, tracked separately
  # in IMPLEMENTATION_PLAN.md Discovered (not in scope for this lint pass).
  case "$model_id" in
    opus|*codex*|*pro*) echo "opus" ;;
    sonnet|gpt-5.4|gemini-3.1-pro*)   echo "sonnet" ;;
    haiku|*mini*|*flash*)              echo "haiku" ;;
    *)                                 echo "sonnet" ;;  # safe default
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
  local raw_classification
  raw_classification=$(classify_task "$task")

  # Extract tier from either single-tier or ranked output
  if echo "$raw_classification" | grep -qE '^[0-9]+\.[a-z]+:'; then
    tier=$(extract_tier_from_ranked "$raw_classification")
  else
    tier="$raw_classification"
  fi

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
