#!/usr/bin/env bash
# Shared bats test helpers (spec 01): hermetic HOME, RALPH_TMP_DIR, mock PATH,
# and a throwaway-project builder for integration tests.
#
# Usage in a *.bats file:
#   load '../helpers/common'

COMMON_BASH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$COMMON_BASH_DIR/.." && pwd)"
SETUP_RALPH_DIR="$(cd "$TESTS_DIR/.." && pwd)"
TEMPLATES_DIR="$SETUP_RALPH_DIR/templates"
export TESTS_DIR SETUP_RALPH_DIR TEMPLATES_DIR

# setup() runs before every test case (bats convention).
setup() {
  # Hermetic HOME: credentials, ~/.codex/sessions, token caches all land here.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"

  # On Windows, python3's os.path.expanduser("~/...") resolves via USERPROFILE
  # (checked before HOME in CPython's ntpath.expanduser), so capacity-claude.sh's
  # `~/.claude/.credentials.json` lookup silently ignores the HOME override above
  # and falls through to the developer's real Windows profile — reading real
  # OAuth credentials and making a real network call to the Anthropic usage API
  # on every check_all_agent_capacity call. Mirroring HOME here closes that gap
  # on Windows Git Bash; harmless no-op on Linux/macOS where USERPROFILE is unused.
  export USERPROFILE="$HOME"

  # All /tmp/ralph-* style scratch files redirect under here (see T1.4).
  export RALPH_TMP_DIR="$BATS_TEST_TMPDIR/ralphtmp"
  mkdir -p "$RALPH_TMP_DIR"

  # Shadow real engine CLIs with tests/mocks/* (directory may not exist yet
  # until T1.3 lands — an absent PATH entry is harmless).
  export PATH="$TESTS_DIR/mocks:$PATH"

  # Conventional locations the mock CLIs (T1.3) will read/write.
  export MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
  export MOCK_SLEEP_LOG="$BATS_TEST_TMPDIR/mock-sleep.log"
}

# teardown() runs after every test case. BATS_TEST_TMPDIR is auto-removed by
# bats-core itself, but we explicitly clear the dirs/env we created so a
# failed or interrupted test never leaks state into the next one.
teardown() {
  rm -rf "${HOME:?}" "${RALPH_TMP_DIR:?}" 2>/dev/null || true
  unset MOCK_LOG MOCK_SLEEP_LOG MOCK_SCENARIO
  unset MOCK_SCENARIO_CLAUDE MOCK_SCENARIO_CODEX MOCK_SCENARIO_AGY
}

# make_temp_project
# Builds a throwaway project dir under BATS_TEST_TMPDIR containing a copy of
# templates/ (scripts/, PROMPT_*.md, ralph.sh, orchestrator.sh) plus an empty
# IMPLEMENTATION_PLAN.md, so a test can run the loop scripts without ever
# touching the real templates/ tree. Prints the project dir path on stdout.
make_temp_project() {
  local project_dir="$BATS_TEST_TMPDIR/project-$RANDOM"
  mkdir -p "$project_dir"

  cp -r "$TEMPLATES_DIR/scripts" "$project_dir/scripts"
  cp "$TEMPLATES_DIR"/PROMPT_*.md "$project_dir/"
  cp "$TEMPLATES_DIR/ralph.sh" "$project_dir/ralph.sh"
  cp "$TEMPLATES_DIR/orchestrator.sh" "$project_dir/orchestrator.sh"
  chmod +x "$project_dir/ralph.sh" "$project_dir/orchestrator.sh" "$project_dir"/scripts/*.sh

  : > "$project_dir/IMPLEMENTATION_PLAN.md"

  echo "$project_dir"
}
