#!/bin/bash
# parse-task.sh — LANE/TIER task annotation parsing and routing lookups.
#
# Ralph v2 task format:
#   - [ ] [LANE:BUILD] [TIER:Moderate] Example task
#
# Supported lanes: ARCH | BUILD | VERIFY | GUI | SCAFFOLD
# Supported tiers: Simple | Moderate | Complex
#
# This file is `source`d by orchestrator.sh and ralph.sh. It assumes
# ralph-routing.conf has been sourced first (for LANE_*_ENGINE /
# LANE_*_FALLBACK / MODEL_${engine}_${tier} variables).
#
# Public functions:
#   parse_task_annotation    "$raw_task"          -> sets TASK_LANE, TASK_TIER, TASK_CLEAN
#   validate_task_annotation "$raw_task"          -> returns 0 if valid, 1 otherwise (with stderr msg)
#   resolve_lane_engine      "$lane"              -> prints engine for lane
#   resolve_lane_fallback    "$lane"              -> prints fallback engine for lane
#   resolve_model            "$engine" "$tier"    -> prints model for [engine+tier]

_SUPPORTED_LANES_REGEX='ARCH|BUILD|VERIFY|GUI|SCAFFOLD'
_SUPPORTED_TIERS_REGEX='Simple|Moderate|Complex'

# Strip common leading prefixes (markdown checkbox + whitespace) and trailing
# CR (Windows line endings) from a raw plan-file line so the annotation regex
# can match cleanly.
_strip_task_prefix() {
  local s="$1"
  s="${s%$'\r'}"                                  # trailing \r
  s="${s#"${s%%[![:space:]]*}"}"                  # leading whitespace
  s="${s#- \[ \] }"                               # optional "- [ ] " checkbox
  s="${s#- \[P\] }"                               # tolerate "- [P] " (parent; rare)
  s="${s#"${s%%[![:space:]]*}"}"                  # any whitespace after the checkbox
  printf '%s' "$s"
}

# parse_task_annotation <raw_task>
# Populates globals: TASK_LANE, TASK_TIER, TASK_CLEAN
# Returns 0 on successful parse, 1 otherwise (globals may be unset on failure).
parse_task_annotation() {
  local raw="$1"
  local stripped
  stripped="$(_strip_task_prefix "$raw")"

  local annotation_re="^\[LANE:(${_SUPPORTED_LANES_REGEX})\][[:space:]]+\[TIER:(${_SUPPORTED_TIERS_REGEX})\][[:space:]]+(.+)$"

  if [[ "$stripped" =~ $annotation_re ]]; then
    TASK_LANE="${BASH_REMATCH[1]}"
    TASK_TIER="${BASH_REMATCH[2]}"
    TASK_CLEAN="${BASH_REMATCH[3]}"
    TASK_CLEAN="${TASK_CLEAN%$'\r'}"
    return 0
  fi

  TASK_LANE=""
  TASK_TIER=""
  TASK_CLEAN=""
  return 1
}

# validate_task_annotation <raw_task>
# Prints an actionable error to stderr naming which field is missing/invalid.
# Returns 0 if valid, 1 otherwise.
validate_task_annotation() {
  local raw="$1"
  local stripped
  stripped="$(_strip_task_prefix "$raw")"

  # Extract (if present) the LANE and TIER fields for field-specific diagnostics.
  local lane="" tier=""
  if [[ "$stripped" =~ \[LANE:([A-Za-z_]+)\] ]]; then
    lane="${BASH_REMATCH[1]}"
  fi
  if [[ "$stripped" =~ \[TIER:([A-Za-z_]+)\] ]]; then
    tier="${BASH_REMATCH[1]}"
  fi

  if [ -z "$lane" ] && [ -z "$tier" ]; then
    echo "ERROR: task is missing both [LANE:X] and [TIER:Y] annotations: ${stripped}" >&2
    echo "       expected: [LANE:ARCH|BUILD|VERIFY|GUI|SCAFFOLD] [TIER:Simple|Moderate|Complex] <description>" >&2
    return 1
  fi
  if [ -z "$lane" ]; then
    echo "ERROR: task is missing [LANE:X] annotation: ${stripped}" >&2
    echo "       expected lanes: ARCH | BUILD | VERIFY | GUI | SCAFFOLD" >&2
    return 1
  fi
  if [ -z "$tier" ]; then
    echo "ERROR: task is missing [TIER:Y] annotation: ${stripped}" >&2
    echo "       expected tiers: Simple | Moderate | Complex" >&2
    return 1
  fi
  if ! [[ "$lane" =~ ^(${_SUPPORTED_LANES_REGEX})$ ]]; then
    echo "ERROR: unsupported lane '[LANE:${lane}]' in task: ${stripped}" >&2
    echo "       expected lanes: ARCH | BUILD | VERIFY | GUI | SCAFFOLD" >&2
    return 1
  fi
  if ! [[ "$tier" =~ ^(${_SUPPORTED_TIERS_REGEX})$ ]]; then
    echo "ERROR: unsupported tier '[TIER:${tier}]' in task: ${stripped}" >&2
    echo "       expected tiers: Simple | Moderate | Complex" >&2
    return 1
  fi

  # Both fields present and valid — final structural check (order, spacing).
  if ! parse_task_annotation "$raw"; then
    echo "ERROR: task annotation is malformed (check ordering and spacing): ${stripped}" >&2
    echo "       expected: [LANE:X] [TIER:Y] <description>" >&2
    return 1
  fi
  return 0
}

# resolve_lane_engine <lane>
# Prints the primary engine for the given lane (from LANE_<LANE>_ENGINE).
# Prints an empty string if the mapping is unset (caller should default).
resolve_lane_engine() {
  local lane="$1"
  local varname="LANE_${lane}_ENGINE"
  printf '%s' "${!varname:-}"
}

# resolve_lane_fallback <lane>
# Prints the fallback engine for the given lane (from LANE_<LANE>_FALLBACK).
resolve_lane_fallback() {
  local lane="$1"
  local varname="LANE_${lane}_FALLBACK"
  printf '%s' "${!varname:-}"
}

# resolve_model <engine> <tier>
# Prints the resolved model ID from MODEL_<engine>_<tier>.
# Returns 0 on success, 1 if the variable is unset or empty.
resolve_model() {
  local engine="$1"
  local tier="$2"
  local varname="MODEL_${engine}_${tier}"
  local value="${!varname:-}"
  if [ -z "$value" ]; then
    echo "ERROR: ${varname} is unset in ralph-routing.conf — cannot resolve model for engine='${engine}' tier='${tier}'" >&2
    return 1
  fi
  printf '%s' "$value"
}
