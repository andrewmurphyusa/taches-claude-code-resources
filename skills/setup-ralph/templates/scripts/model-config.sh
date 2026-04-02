#!/bin/bash
# Model configuration constants for improved-ralph orchestrator
# These are the model tier aliases accepted by Claude Code CLI

# ============================================================================
# CLAUDE MODEL TIER ALIASES (backward-compatible; used with --model flag)
# ============================================================================
MODEL_HAIKU="haiku"
MODEL_SONNET="sonnet"
MODEL_OPUS="opus"

# Default model when classification is ambiguous
MODEL_DEFAULT="$MODEL_SONNET"

# Per-provider model IDs for each tier
# Claude (existing aliases — unchanged for backward compat)
CLAUDE_MODEL_OPUS="opus"
CLAUDE_MODEL_SONNET="sonnet"
CLAUDE_MODEL_HAIKU="haiku"

# Codex (OpenAI)
# opus  → gpt-5.3-codex: deep coding specialist with best SWE-Bench score
# sonnet→ gpt-5.4:       general-purpose, 1M context, absorbs coding capabilities
# haiku → gpt-5.4-mini:  fast/cheap variant for simple edits
CODEX_MODEL_OPUS="gpt-5.3-codex"
CODEX_MODEL_SONNET="gpt-5.4"
CODEX_MODEL_HAIKU="gpt-5.4-mini"

# Antigravity/Gemini (invoked via gemini CLI binary)
# opus  → gemini-3.1-pro-preview: complex reasoning, 1M context, planning/review
# sonnet→ gemini-3.1-pro-preview: same model; lower thinking tier at runtime
# haiku → gemini-3-flash:         fast/lightweight for simple tasks
GEMINI_MODEL_OPUS="gemini-3.1-pro-preview"
GEMINI_MODEL_SONNET="gemini-3.1-pro-preview"
GEMINI_MODEL_HAIKU="gemini-3-flash"

# ============================================================================
# MULTI-ENGINE REGISTRY
# ============================================================================

# ENGINES: space-separated list of active engine names.
# Override via RALPH_ENGINES env var to add/remove engines.
# Capacity scripts and scoring rows must exist for each listed engine.
ENGINES="${RALPH_ENGINES:-claude codex gemini}"

# CLI dispatch prefixes per engine.
# These document the binary used; actual dispatch is in orchestrator.sh invoke_engine().
ENGINES_CLI_claude="ralph.sh"       # delegates to ralph.sh (existing path)
ENGINES_CLI_codex="codex exec"      # Codex CLI headless mode
ENGINES_CLI_gemini="gemini"         # Gemini CLI (headless via -p flag)

# Multi-engine gate: set RALPH_MULTI_ENGINE=true to enable multi-engine routing.
# Default is false (Claude-only) for backward compatibility.
# Can be overridden via env var or per-hostname in auth/engines-config.json.
RALPH_MULTI_ENGINE="${RALPH_MULTI_ENGINE:-false}"

# ============================================================================
# FUNCTIONS
# ============================================================================

# get_model_for_tier <engine> <tier>
# Returns the model ID for the given engine+tier combination.
# Usage: model=$(get_model_for_tier "codex" "opus")  → "gpt-5.3-codex"
get_model_for_tier() {
  local engine="$1"
  local tier="$2"
  local upper_engine upper_tier varname

  # Normalize to upper case for variable lookup
  upper_engine=$(echo "$engine" | tr '[:lower:]' '[:upper:]')
  upper_tier=$(echo "$tier" | tr '[:lower:]' '[:upper:]')

  # Build variable name: e.g. CODEX_MODEL_OPUS
  varname="${upper_engine}_MODEL_${upper_tier}"

  # Indirect variable expansion (bash)
  local model="${!varname:-}"

  if [ -z "$model" ]; then
    # Fallback: return the tier alias itself (works for Claude's haiku/sonnet/opus aliases)
    echo "$tier"
  else
    echo "$model"
  fi
}

# validate_model <model>
# Accepts either a Claude tier alias (haiku|sonnet|opus) or any non-empty string
# for provider-qualified model IDs (e.g., gpt-5.3-codex, gemini-3.1-pro-preview).
validate_model() {
  local model="$1"
  case "$model" in
    haiku|sonnet|opus) return 0 ;;
    "")
      echo "Error: model cannot be empty"
      return 1
      ;;
    *)
      # Accept any non-empty string as a valid model ID (provider-qualified IDs)
      return 0
      ;;
  esac
}

# upgrade_tier <tier>
# Upgrades a Claude tier alias one step: haiku -> sonnet -> opus -> opus
# For provider-qualified model IDs, maps to the next Claude tier alias.
upgrade_tier() {
  local tier="$1"
  case "$tier" in
    haiku)  echo "sonnet" ;;
    sonnet) echo "opus" ;;
    opus)   echo "opus" ;;
    *)      echo "sonnet" ;;
  esac
}
