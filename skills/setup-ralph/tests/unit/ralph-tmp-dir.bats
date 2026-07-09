#!/usr/bin/env bats
# T1.4: RALPH_TMP_DIR — every hardcoded /tmp/ralph-* scratch path across
# templates/ and templates/scripts/ must resolve through
# "${RALPH_TMP_DIR:-/tmp}/..." so tests (and any future non-default
# deployment) can redirect scratch files away from the real /tmp. Default
# (RALPH_TMP_DIR unset) behavior must be unchanged.

load '../helpers/common'

@test "no hardcoded /tmp/ralph-* paths remain in templates/ or templates/scripts/" {
  # .reference/architecture-reference.md is prose regenerated in T7.4 (out of
  # scope here) and is not a .sh file, so the --include filter excludes it.
  run grep -rn '/tmp/ralph' "$TEMPLATES_DIR" --include='*.sh'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "capacity-claude.sh: CAPACITY_CACHE_FILE honors RALPH_TMP_DIR override" {
  export RALPH_TMP_DIR="$BATS_TEST_TMPDIR/custom-tmp"
  mkdir -p "$RALPH_TMP_DIR"
  source "$TEMPLATES_DIR/scripts/capacity-claude.sh"

  [ "$CAPACITY_CACHE_FILE" = "$RALPH_TMP_DIR/ralph-usage-cache.json" ]
}

@test "capacity-claude.sh: CAPACITY_CACHE_FILE falls back to /tmp when RALPH_TMP_DIR unset" {
  # Run in a subshell so unsetting RALPH_TMP_DIR here never leaks into this
  # test's own teardown() (which does rm -rf "\${RALPH_TMP_DIR:?}").
  run bash -c "unset RALPH_TMP_DIR; source '$TEMPLATES_DIR/scripts/capacity-claude.sh'; echo \"\$CAPACITY_CACHE_FILE\""

  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/ralph-usage-cache.json" ]
}

@test "capacity-codex.sh: estimate file honors RALPH_TMP_DIR override" {
  export RALPH_TMP_DIR="$BATS_TEST_TMPDIR/custom-tmp"
  mkdir -p "$RALPH_TMP_DIR"
  source "$TEMPLATES_DIR/scripts/capacity-codex.sh"

  [ "$_CODEX_ESTIMATE_FILE" = "$RALPH_TMP_DIR/ralph-codex-reset.epoch" ]
}

@test "capacity-codex.sh: estimate file falls back to /tmp when RALPH_TMP_DIR unset" {
  run bash -c "unset RALPH_TMP_DIR; source '$TEMPLATES_DIR/scripts/capacity-codex.sh'; echo \"\$_CODEX_ESTIMATE_FILE\""

  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/ralph-codex-reset.epoch" ]
}

@test "capacity-gemini.sh: estimate + last-error files honor RALPH_TMP_DIR override" {
  export RALPH_TMP_DIR="$BATS_TEST_TMPDIR/custom-tmp"
  mkdir -p "$RALPH_TMP_DIR"
  source "$TEMPLATES_DIR/scripts/capacity-gemini.sh"

  [ "$_GEMINI_ESTIMATE_FILE" = "$RALPH_TMP_DIR/ralph-gemini-reset.epoch" ]
  [ "$_GEMINI_LAST_ERROR_FILE" = "$RALPH_TMP_DIR/ralph-gemini-last-error.json" ]
}

@test "capacity-gemini.sh: estimate + last-error files fall back to /tmp when RALPH_TMP_DIR unset" {
  run bash -c "unset RALPH_TMP_DIR; source '$TEMPLATES_DIR/scripts/capacity-gemini.sh'; echo \"\$_GEMINI_ESTIMATE_FILE|\$_GEMINI_LAST_ERROR_FILE\""

  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/ralph-gemini-reset.epoch|/tmp/ralph-gemini-last-error.json" ]
}

@test "ralph.sh: prompt tmp file mktemp template is RALPH_TMP_DIR-aware" {
  run grep -c 'mktemp "\${RALPH_TMP_DIR:-/tmp}/ralph-prompt-XXXXXX.md"' "$TEMPLATES_DIR/ralph.sh"

  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "orchestrator.sh: codex/gemini reset-epoch writes are RALPH_TMP_DIR-aware" {
  run grep -c '"\${RALPH_TMP_DIR:-/tmp}/ralph-codex-reset.epoch"' "$TEMPLATES_DIR/orchestrator.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]

  run grep -c '"\${RALPH_TMP_DIR:-/tmp}/ralph-gemini-reset.epoch"' "$TEMPLATES_DIR/orchestrator.sh"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}
