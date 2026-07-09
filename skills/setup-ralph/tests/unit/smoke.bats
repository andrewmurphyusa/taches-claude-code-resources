#!/usr/bin/env bats
# Trivial pipeline smoke test: proves vendored bats + helpers/common.bash +
# sourcing a template script all work together end-to-end.

load '../helpers/common'

@test "model-config.sh: upgrade_tier haiku -> sonnet" {
  source "$TEMPLATES_DIR/scripts/model-config.sh"

  run upgrade_tier haiku

  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}
