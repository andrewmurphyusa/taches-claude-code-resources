#!/usr/bin/env bats
# T1.7: Characterization of the CURRENT single-engine build loop
# (orchestrator.sh build stage, RALPH_MULTI_ENGINE unset/false, engine=claude).
# Pins actual behavior as the Priority-2 refactor's safety net — including two
# surprises found while writing this test (see IMPLEMENTATION_PLAN.md's T1.7
# handoff note for details):
#   1. ralph.sh truncates ($LOG_FILE >) at the START of every invocation, so the
#      FINAL ralph.log after N iterations holds only the LAST iteration's
#      session header; the earlier N-1 headers land in ralph.accumulated.log
#      instead (moved there by ralph.sh's own "cat $LOG_FILE >> $ACCUMULATED"
#      step, which runs before the truncating write). This test asserts the
#      real split, not "3 headers in ralph.log".
#   2. NEXT-TASK.md is deleted by orchestrator.sh's own `trap orchestrator_cleanup
#      EXIT` before a `run`-wrapped invocation returns control to the test, so
#      its first-iteration content is captured via the mocks' NEXT-TASK.md
#      snapshot (mock_log_project_file, added to tests/mocks/_common.sh
#      alongside this test) rather than inspected on disk after the run.

load '../helpers/common'

@test "single-engine build loop: 3-task plan drives mock claude to ALL TASKS COMPLETE" {
  project_dir="$(make_temp_project)"
  cd "$project_dir" || return 1

  cat > IMPLEMENTATION_PLAN.md <<'EOF'
# Test Plan

- [ ] Task 1: implement the first thing
- [ ] Task 2: implement the second thing
- [ ] Task 3: implement the third thing
EOF

  export RALPH_BACKUP=false
  export MOCK_SCENARIO=success
  export MOCK_TOUCH_PLAN="$project_dir/IMPLEMENTATION_PLAN.md"

  run bash orchestrator.sh 5

  # --- Exit status and completion banner ---
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL TASKS COMPLETE"* ]]

  # --- Plan file: all 3 tasks flipped to [x] by the mock ---
  run grep -c '^\s*- \[x\]' IMPLEMENTATION_PLAN.md
  [ "$output" -eq 3 ]

  # --- Mock invoked exactly 3 times (one per task; loop stopped on completion
  #     check before a 4th invocation, despite the 5-iteration limit) ---
  [ -f "$MOCK_LOG" ]
  call_count=$(grep -c -- '--- CALL ---' "$MOCK_LOG")
  [ "$call_count" -eq 3 ]

  # --- Every call carried --model and -p (ralph.sh's invoke_claude args) ---
  model_flag_count=$(grep -c '^  --model$' "$MOCK_LOG")
  [ "$model_flag_count" -eq 3 ]
  p_flag_count=$(grep -c '^  -p$' "$MOCK_LOG")
  [ "$p_flag_count" -eq 3 ]

  # --- NEXT-TASK.md existed during the run and held task 1's text on the
  #     first call (captured via the mock's NEXT-TASK.md snapshot, since the
  #     file itself is gone by the time `run` returns — see header comment) ---
  first_next_task=$(awk '/^FILE: NEXT-TASK\.md$/{getline; print; exit}' "$MOCK_LOG")
  [ "$first_next_task" = "Task 1: implement the first thing" ]

  # --- NEXT-TASK.md is cleaned up by orchestrator.sh's EXIT trap once the
  #     whole run finishes (RALPH_ORCHESTRATED mode never leaves it behind) ---
  [ ! -f NEXT-TASK.md ]

  # --- ralph.log: truncated to just the LAST iteration's header (see surprise
  #     #1 above) — exactly one session header, not three ---
  [ -f ralph.log ]
  final_log_headers=$(grep -c '=== Ralph Session Started' ralph.log)
  [ "$final_log_headers" -eq 1 ]

  # --- ralph.accumulated.log: holds the 2 earlier iterations' headers that
  #     got rotated out of ralph.log before each truncating write ---
  [ -f ralph.accumulated.log ]
  accumulated_log_headers=$(grep -c '=== Ralph Session Started' ralph.accumulated.log)
  [ "$accumulated_log_headers" -eq 2 ]

  # --- Total session headers across both files == number of ralph.sh
  #     invocations (3) ---
  [ "$((final_log_headers + accumulated_log_headers))" -eq 3 ]
}
