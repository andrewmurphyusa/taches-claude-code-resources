#!/bin/bash
# Model configuration constants for improved-ralph orchestrator
# These are the model tier aliases accepted by Claude Code CLI

# Model tier aliases (used with --model flag)
MODEL_HAIKU="haiku"
MODEL_SONNET="sonnet"
MODEL_OPUS="opus"

# Default model when classification is ambiguous
MODEL_DEFAULT="$MODEL_SONNET"

# Validate a model value against the whitelist
# Usage: validate_model "haiku"
validate_model() {
  local model="$1"
  case "$model" in
    haiku|sonnet|opus) return 0 ;;
    *)
      echo "Error: Invalid model '$model'. Allowed: haiku, sonnet, opus"
      return 1
      ;;
  esac
}

# Upgrade a model tier by one step
# haiku -> sonnet, sonnet -> opus, opus -> opus
upgrade_tier() {
  local tier="$1"
  case "$tier" in
    haiku)  echo "sonnet" ;;
    sonnet) echo "opus" ;;
    opus)   echo "opus" ;;
    *)      echo "sonnet" ;;
  esac
}
