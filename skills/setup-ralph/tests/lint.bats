#!/usr/bin/env bats
# shellcheck lint over every .sh file under templates/ and templates/scripts/.
#
# This complements (rather than replaces) the shellcheck phase already run by
# tests/run.sh: running it here too means `bats -r tests/` alone (no run.sh)
# still catches lint regressions, and per-file failures are reported with
# bats' usual pass/fail granularity instead of one combined shellcheck dump.

load 'helpers/common'

# require_shellcheck
# Skips the calling test if shellcheck isn't on PATH. Deliberately not a
# setup() override — that would shadow helpers/common.bash's setup(), which
# initializes HOME/RALPH_TMP_DIR that its teardown() unconditionally cleans up.
require_shellcheck() {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
}

# collect_shell_files <dir>
# Prints one absolute path per line for every *.sh file found (recursively)
# under <dir>. Portable find+read loop (no mapfile — bash 3.2 compatible).
collect_shell_files() {
  local dir="$1"
  find "$dir" -name '*.sh' -print
}

@test "shellcheck: templates/*.sh has no findings" {
  require_shellcheck
  local f
  while IFS= read -r f; do
    run shellcheck "$f"
    [ "$status" -eq 0 ] || {
      echo "shellcheck findings in $f:"
      echo "$output"
      return 1
    }
  done < <(find "$TEMPLATES_DIR" -maxdepth 1 -name '*.sh')
}

@test "shellcheck: templates/scripts/*.sh has no findings" {
  require_shellcheck
  local f
  while IFS= read -r f; do
    run shellcheck "$f"
    [ "$status" -eq 0 ] || {
      echo "shellcheck findings in $f:"
      echo "$output"
      return 1
    }
  done < <(collect_shell_files "$TEMPLATES_DIR/scripts")
}
