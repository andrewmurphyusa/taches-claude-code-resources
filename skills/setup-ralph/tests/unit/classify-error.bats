#!/usr/bin/env bats
# T1.6: Characterization tests for classify_error's error-fixture table (spec 01,
# item 2 of the phase's characterization tests).
#
# These tests pin CURRENT behavior of `classify_error` in error-handler.sh
# against real captured-style error text so the Priority-2 plugin refactor
# (T2.8 rewrites classify_error to assemble patterns from loaded engines'
# ENGINE_*_ERR_* vars instead of one hardcoded function) has a safety net:
# if any of these flip unexpectedly post-refactor, that's a regression, not
# a characterization update.
#
# Coverage per spec 01: claude/codex/gemini x
# {USAGE_EXHAUSTED, RATE_LIMIT, AUTH_FAILURE, CONTEXT_TOO_LONG} (12 cases),
# + claude-only OVERLOADED, + engine-agnostic UNKNOWN, + the documented
# missing-file fallback. 15 cases total.
#
# Fixtures live under tests/fixtures/errors/<engine>-<type>.txt (one file per
# case) and were authored from the same real-world error strings already
# cited in error-handler.sh's own header comment (Codex/Gemini issue-tracker
# wording) and in tests/mocks/{claude,codex,agy} (T1.3) — then verified
# empirically against the actual `classify_error` output (a scratch probe
# loop over every fixture) before being pinned here, not hand-derived from
# reading the grep patterns.

load '../helpers/common'

# ----------------------------------------------------------------------------
# Claude
# ----------------------------------------------------------------------------

@test "classify_error: claude usage-limit fixture -> USAGE_EXHAUSTED" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/claude-usage_exhausted.txt"

  [ "$output" = "USAGE_EXHAUSTED" ]
}

@test "classify_error: claude rate_limit_error fixture -> RATE_LIMIT" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/claude-rate_limit.txt"

  [ "$output" = "RATE_LIMIT" ]
}

@test "classify_error: claude authentication_error fixture -> AUTH_FAILURE" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/claude-auth_failure.txt"

  [ "$output" = "AUTH_FAILURE" ]
}

@test "classify_error: claude context-length fixture -> CONTEXT_TOO_LONG" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/claude-context_too_long.txt"

  [ "$output" = "CONTEXT_TOO_LONG" ]
}

@test "classify_error: claude overloaded_error fixture -> OVERLOADED (claude-only per spec 01)" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/claude-overloaded.txt"

  [ "$output" = "OVERLOADED" ]
}

# ----------------------------------------------------------------------------
# Codex
# ----------------------------------------------------------------------------

@test "classify_error: codex 5-hour-limit fixture -> USAGE_EXHAUSTED" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/codex-usage_exhausted.txt"

  [ "$output" = "USAGE_EXHAUSTED" ]
}

@test "classify_error: codex rate_limit_exceeded fixture -> RATE_LIMIT" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/codex-rate_limit.txt"

  [ "$output" = "RATE_LIMIT" ]
}

@test "classify_error: codex 401/login-required fixture -> AUTH_FAILURE" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/codex-auth_failure.txt"

  [ "$output" = "AUTH_FAILURE" ]
}

@test "classify_error: codex context-length fixture -> CONTEXT_TOO_LONG" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/codex-context_too_long.txt"

  [ "$output" = "CONTEXT_TOO_LONG" ]
}

# ----------------------------------------------------------------------------
# Gemini (still classified today — retirement to templates-deprecated/ is
# Priority 4/T4.4, out of scope here; classify_error's Gemini patterns are
# current production behavior and must stay pinned until that task lands)
# ----------------------------------------------------------------------------

@test "classify_error: gemini TerminalQuotaError/RESOURCE_EXHAUSTED fixture -> USAGE_EXHAUSTED" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/gemini-usage_exhausted.txt"

  [ "$output" = "USAGE_EXHAUSTED" ]
}

@test "classify_error: gemini RATE_LIMIT_EXCEEDED/quota-metric fixture -> RATE_LIMIT" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/gemini-rate_limit.txt"

  [ "$output" = "RATE_LIMIT" ]
}

@test "classify_error: gemini Unauthorized/API-key fixture -> AUTH_FAILURE" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/gemini-auth_failure.txt"

  [ "$output" = "AUTH_FAILURE" ]
}

@test "classify_error: gemini context-length fixture -> CONTEXT_TOO_LONG" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/gemini-context_too_long.txt"

  [ "$output" = "CONTEXT_TOO_LONG" ]
}

# ----------------------------------------------------------------------------
# Engine-agnostic: UNKNOWN + missing-file fallback
# ----------------------------------------------------------------------------

@test "classify_error: unrecognized error text -> UNKNOWN" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/unknown.txt"

  [ "$output" = "UNKNOWN" ]
}

@test "classify_error: missing output file -> UNKNOWN (documented fallback)" {
  source "$TEMPLATES_DIR/scripts/error-handler.sh"

  run classify_error "$TESTS_DIR/fixtures/errors/does-not-exist.txt"

  [ "$output" = "UNKNOWN" ]
}
