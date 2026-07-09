#!/bin/bash
# Test suite entry point for skills/setup-ralph.
#
# 1. Runs shellcheck over templates/*.sh and templates/scripts/**/*.sh
#    (skipped with a loud warning if shellcheck is not installed).
# 2. Runs every tests/**/*.bats file via the vendored bats-core, falling
#    back to a system-installed `bats` if vendoring is missing.
#
# Works from any CWD, on Git Bash, WSL/Linux, and macOS.
set -uo pipefail
# NOTE: no `set -e` — both phases below must always run so a shellcheck
# failure never hides bats results (and vice versa). Exit status is the
# combination of both phases, computed at the bottom.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_RALPH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES_DIR="$SETUP_RALPH_DIR/templates"
BATS_BIN="$SCRIPT_DIR/vendor/bats-core/bin/bats"

lint_status=0
test_status=0

# ------------------------------------------------------------------------
# 1. shellcheck pass
# ------------------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  echo "==> shellcheck: templates/*.sh + templates/scripts/**/*.sh"

  shell_files=()
  while IFS= read -r -d '' f; do
    shell_files+=("$f")
  done < <(find "$TEMPLATES_DIR" -maxdepth 1 -name '*.sh' -print0)
  if [ -d "$TEMPLATES_DIR/scripts" ]; then
    while IFS= read -r -d '' f; do
      shell_files+=("$f")
    done < <(find "$TEMPLATES_DIR/scripts" -name '*.sh' -print0)
  fi

  if [ "${#shell_files[@]}" -gt 0 ]; then
    shellcheck "${shell_files[@]}"
    lint_status=$?
  else
    echo "    (no .sh files found under templates/)"
  fi
else
  echo "WARNING: shellcheck not found on PATH — skipping lint pass." >&2
  echo "         Install shellcheck to catch shell scripting issues locally." >&2
fi

# ------------------------------------------------------------------------
# 2. bats test suite
# ------------------------------------------------------------------------
if [ -x "$BATS_BIN" ]; then
  echo "==> bats (vendored, $("$BATS_BIN" --version)): tests/**/*.bats"
  "$BATS_BIN" -r "$SCRIPT_DIR"
  test_status=$?
elif command -v bats >/dev/null 2>&1; then
  echo "WARNING: vendored bats-core not found at $BATS_BIN — falling back to" >&2
  echo "         a system-installed bats. Please vendor bats-core manually" >&2
  echo "         into tests/vendor/bats-core/ (see specs/01-test-harness.md)." >&2
  echo "==> bats (system, $(bats --version)): tests/**/*.bats"
  bats -r "$SCRIPT_DIR"
  test_status=$?
else
  echo "ERROR: no bats found — neither vendored (tests/vendor/bats-core/bin/bats)" >&2
  echo "       nor a system-installed 'bats' on PATH. Cannot run tests." >&2
  echo "       Vendor bats-core into tests/vendor/bats-core/ or install bats-core." >&2
  test_status=1
fi

# ------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------
echo "==> summary: shellcheck=$([ "$lint_status" -eq 0 ] && echo pass || echo FAIL) bats=$([ "$test_status" -eq 0 ] && echo pass || echo FAIL)"

if [ "$lint_status" -ne 0 ] || [ "$test_status" -ne 0 ]; then
  exit 1
fi
exit 0
