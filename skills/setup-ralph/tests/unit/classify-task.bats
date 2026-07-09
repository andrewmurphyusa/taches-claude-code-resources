#!/usr/bin/env bats
# T1.5: Characterization tests for classify_task's tier table (spec 01, item 1).
#
# These tests pin CURRENT behavior of `classify_task` (single-engine mode,
# i.e. `_classify_task_single`) in classify-task.sh so the Priority-2 plugin
# refactor (T2.9 rewrites classify-task.sh to source fit/tier data from
# engine plugins instead of hardcoded rows) has a safety net: if any of
# these flip unexpectedly post-refactor, that's a regression, not a
# characterization update.
#
# Coverage (per spec 01's required categories, all with RALPH_MULTI_ENGINE
# unset/false — the default): [tier] prefix override, opus keywords, haiku
# keywords, haiku negative-constraint + length-limit disqualifiers, sonnet
# default, structural upgrades (length / file-count / risk-signal), and the
# empty-task case. 29 cases total (spec asks for >=15).

load '../helpers/common'

# ----------------------------------------------------------------------------
# Empty task
# ----------------------------------------------------------------------------

@test "classify_task: empty task defaults to MODEL_DEFAULT (sonnet)" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task ""

  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}

# ----------------------------------------------------------------------------
# [tier] prefix override — wins even when the task body would otherwise
# classify differently (Step 0 returns immediately, before any keyword scan).
# ----------------------------------------------------------------------------

@test "classify_task: [opus] prefix overrides a haiku-shaped body" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "[opus] fix a typo in the header"

  [ "$output" = "opus" ]
}

@test "classify_task: [sonnet] prefix overrides a haiku-shaped body" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "[sonnet] rename the helper function"

  [ "$output" = "sonnet" ]
}

@test "classify_task: [haiku] prefix overrides an opus-shaped body" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "[haiku] investigate why the deployment failed"

  [ "$output" = "haiku" ]
}

# ----------------------------------------------------------------------------
# Opus keywords (Step 1: force-opus signals)
# ----------------------------------------------------------------------------

@test "classify_task: leading 'why ' forces opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "why is memory usage climbing"

  [ "$output" = "opus" ]
}

@test "classify_task: 'architect' keyword is opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "architect a new event-driven pipeline"

  [ "$output" = "opus" ]
}

@test "classify_task: 'design a ' keyword is opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "design a rate limiter for the API gateway"

  [ "$output" = "opus" ]
}

@test "classify_task: 'investigate' keyword is opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "investigate the flaky integration test"

  [ "$output" = "opus" ]
}

@test "classify_task: 'refactor the entire' keyword is opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "refactor the entire billing module"

  [ "$output" = "opus" ]
}

@test "classify_task: 'migrate' keyword is opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "migrate the legacy queue to Kafka"

  [ "$output" = "opus" ]
}

@test "classify_task: 'audit the' keyword is opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "audit the authentication flow for vulnerabilities"

  [ "$output" = "opus" ]
}

# ----------------------------------------------------------------------------
# Haiku keywords (Step 2, no disqualifiers): tier stays haiku
# ----------------------------------------------------------------------------

@test "classify_task: 'rename' keyword is haiku" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "rename the config variable foo to bar"

  [ "$output" = "haiku" ]
}

@test "classify_task: 'fix typo' keyword is haiku" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "fix typo in the changelog"

  [ "$output" = "haiku" ]
}

@test "classify_task: 'bump version' keyword is haiku" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "bump version to 3.2.1"

  [ "$output" = "haiku" ]
}

@test "classify_task: 'add comment' keyword is haiku" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "add comment explaining the retry logic"

  [ "$output" = "haiku" ]
}

@test "classify_task: 'format' keyword is haiku" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "format the JSON output for logs"

  [ "$output" = "haiku" ]
}

# ----------------------------------------------------------------------------
# Haiku negative constraints: a haiku keyword match is disqualified when a
# negative-constraint phrase is also present ('ensure|without breaking|
# while preserving|backward compat'). What happens NEXT differs depending on
# whether that same phrase also happens to match the *separate* Step-4
# risk-signal grep ('without breaking|ensure backward|while preserving|and
# also') — the two keyword lists are similar but not identical, which is a
# real (if subtle) asymmetry in the current implementation worth pinning.
# ----------------------------------------------------------------------------

@test "classify_task: haiku keyword + 'without breaking' disqualifies haiku AND matches the upgrade risk-signal -> opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "rename variable foo to bar without breaking any callers"

  [ "$output" = "opus" ]
}

@test "classify_task: haiku keyword + 'backward compat' disqualifies haiku but does NOT match the upgrade risk-signal -> sonnet" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  # Disqualifier list matches bare "backward compat"; the Step-4 upgrade
  # risk-signal list only matches the more specific "ensure backward" — so
  # this task falls through to the sonnet default without being upgraded.
  run classify_task "update docstring to maintain backward compat"

  [ "$output" = "sonnet" ]
}

# ----------------------------------------------------------------------------
# Haiku length limit: haiku keyword tasks >= 150 chars are disqualified
# (exact boundary; length is measured on the raw task string).
# ----------------------------------------------------------------------------

@test "classify_task: haiku keyword task at 149 chars stays haiku" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  local base="rename "
  local filler
  filler=$(printf 'x%.0s' $(seq 1 142)) # 7 + 142 = 149
  local task="${base}${filler}"
  [ "${#task}" -eq 149 ]

  run classify_task "$task"

  [ "$output" = "haiku" ]
}

@test "classify_task: haiku keyword task at 150 chars is disqualified (length limit) -> sonnet" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  local base="rename "
  local filler
  filler=$(printf 'x%.0s' $(seq 1 143)) # 7 + 143 = 150
  local task="${base}${filler}"
  [ "${#task}" -eq 150 ]

  run classify_task "$task"

  [ "$output" = "sonnet" ]
}

# ----------------------------------------------------------------------------
# Sonnet default: no opus/haiku keyword hits, no structural modifiers.
# ----------------------------------------------------------------------------

@test "classify_task: plain implementation task with no keyword hits defaults to sonnet" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "implement a new endpoint for user profile updates"

  [ "$output" = "sonnet" ]
}

@test "classify_task: another plain task with no keyword hits defaults to sonnet" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "add support for pagination in the search results"

  [ "$output" = "sonnet" ]
}

# ----------------------------------------------------------------------------
# Structural upgrades (Step 4, applied to the sonnet default, first match
# wins: length > 200, else 3+ file mentions, else risk-signal phrase).
# ----------------------------------------------------------------------------

@test "classify_task: no-keyword task at exactly 200 chars is NOT upgraded (boundary) -> sonnet" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  local base="update config "
  local filler
  filler=$(printf 'x%.0s' $(seq 1 186)) # 14 + 186 = 200
  local task="${base}${filler}"
  [ "${#task}" -eq 200 ]

  run classify_task "$task"

  [ "$output" = "sonnet" ]
}

@test "classify_task: no-keyword task at 201 chars is upgraded via length -> opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  local base="update config "
  local filler
  filler=$(printf 'x%.0s' $(seq 1 187)) # 14 + 187 = 201
  local task="${base}${filler}"
  [ "${#task}" -eq 201 ]

  run classify_task "$task"

  [ "$output" = "opus" ]
}

@test "classify_task: 3+ file mentions upgrades sonnet -> opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "update src/foo.py, src/bar.py, and src/baz.py to use the new shared logger"

  [ "$output" = "opus" ]
}

@test "classify_task: 2 file mentions (boundary, below the 3+ threshold) does NOT upgrade -> sonnet" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "update src/foo.py and src/bar.py to use the new shared logger"

  [ "$output" = "sonnet" ]
}

@test "classify_task: 'and also' risk signal upgrades sonnet -> opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run classify_task "update the header spacing and also fix the footer alignment issue"

  [ "$output" = "opus" ]
}

# ----------------------------------------------------------------------------
# extract_tier_from_ranked: characterization of a KNOWN, tracked bug (see
# IMPLEMENTATION_PLAN.md "## Discovered", entry "found during T1.2,
# 2026-07-08" on classify-task.sh's extract_tier_from_ranked). The opus arm's
# `*pro*` wildcard shadows the sonnet arm's `gemini-3.1-pro*` pattern, so the
# actually-configured GEMINI_MODEL_SONNET="gemini-3.1-pro-preview"
# (model-config.sh) is misclassified as opus tier instead of sonnet.
#
# T1.5 scope is explicitly "classify_task tier table" (a different function
# from extract_tier_from_ranked, which only matters in multi-engine mode via
# classify_task_multi/should_decompose). Per this task's instructions:
# deliberately NOT fixing it here — extract_tier_from_ranked's hardcoded
# tier-mapping rows are wholesale replaced by T2.9 ("classify-task.sh: fit
# matrix/speed/reliability from plugin vars; delete hardcoded rows"), so a
# fix now would just be re-litigated there. This test pins the CURRENT
# (buggy) behavior so it's visible and intentional, not silently ignored.
# ----------------------------------------------------------------------------

@test "extract_tier_from_ranked: KNOWN BUG - configured gemini sonnet model ID misclassifies as opus" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  # GEMINI_MODEL_SONNET is "gemini-3.1-pro-preview" per model-config.sh, i.e.
  # this SHOULD ideally be "sonnet" — but the opus arm's *pro* wildcard
  # matches first. See comment block above; tracked in
  # IMPLEMENTATION_PLAN.md's Discovered section, not fixed in T1.5.
  run extract_tier_from_ranked "1.gemini:gemini-3.1-pro-preview 2.claude:sonnet"

  [ "$output" = "opus" ]
}

@test "extract_tier_from_ranked: unaffected engines/tiers classify correctly (contrast case)" {
  source "$TEMPLATES_DIR/scripts/classify-task.sh"

  run extract_tier_from_ranked "1.codex:gpt-5.4-mini 2.claude:haiku"

  [ "$output" = "haiku" ]
}
