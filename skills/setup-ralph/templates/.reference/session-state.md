### Objective
Fully analyze the Ralph Wiggum loop planning implementation across orchestrator.sh, ralph.sh, scripts/, and PROMPT_*.md files. Produce a reusable architecture reference.

### Current Phase
Phase 6 — COMPLETE

### Phase Status
- [x] Phase 1: Entry-point trace
- [x] Phase 2: Planning flow
- [x] Phase 3: File I/O and plan-file behavior
- [x] Phase 4: Custom input support
- [x] Phase 5: Dead code and control points
- [x] Phase 6: Final synthesis — artifacts written

### Confirmed Findings

**Entry Point**
- `orchestrator.sh plan` sets STAGE="plan" (line 217) or via --stage/--stage=plan
- orchestrator.sh directly invokes `ralph.sh` via `bash "$LOOP_SH" "plan" "1" "--model" "$PLAN_MODEL"` (line 566)
- LOOP_SH defaults to `$ORCHESTRATOR_DIR/ralph.sh` (line 105); overridable via RALPH_LOOP_SH env

**Planning Flow**
- ralph.sh: `plan` positional arg → MODE="plan" → PROMPT_FILE="PROMPT_plan.md"
- Sources: stuck-tracker.sh (line 235), capacity-monitor.sh (lines 243-247)
- Claude invoked as: `cat PROMPT_plan.md | claude --model $MODEL -p --dangerously-skip-permissions --output-format text` (line 579)
- Plan mode never calls init_stuck_tracker; does not use NEXT-TASK.md

**File I/O (plan mode)**
- READ: PROMPT_plan.md, RALPH_STATUS.txt, ralph.log (prior), ~/.claude-oauth-token
- WRITTEN: ralph.log (tee -a), ralph.accumulated.log (prior log saved), IMPLEMENTATION_PLAN.md (by claude)
- orchestrator.sh also writes RALPH_STATUS.txt="RUNNING" (line 501) before plan loop

**IMPLEMENTATION_PLAN.md behavior**
- If exists: claude reads it (PROMPT_plan.md step 0b: "Study @IMPLEMENTATION_PLAN.md") and updates/merges
- If missing: claude creates it from scratch
- Done detection: orchestrator checks mtime before/after each plan iteration (lines 556-609)
  - If mtime unchanged → "Planning complete" → exit 0
  - If mtime changed → continue to next iteration
- Max iterations: RALPH_PLAN_MAX_ITERATIONS (default 5)

**Custom input support**
- NOT SUPPORTED — no CLI flag, no env var, no code path for custom input files
- Only indirection: modify PROMPT_plan.md to change what claude reads

**Dead code in plan mode**
- stuck-tracker functions sourced but unused (init_stuck_tracker, update_stuck_tracker, is_stuck, skip_stuck_task)
- check_all_tasks_complete / get_current_task defined in ralph.sh but not called in plan mode
- push_to_backup, print_iteration_summary, generate_report never called in plan mode
- cleanup() skips generate_report (only runs for build mode, line 435)

**Template/runtime gaps**
- PROMPT_plan.md references specs/*, src/lib/*, src/* — assumes target project structure
- No {{...}} placeholders in shell scripts; paths are computed at runtime

### Open Questions
None — all phases resolved.

### Files Inspected
- skills/setup-ralph/templates/orchestrator.sh (full, ~1047 lines)
- skills/setup-ralph/templates/ralph.sh (full, 599 lines)
- skills/setup-ralph/templates/scripts/stuck-tracker.sh
- skills/setup-ralph/templates/scripts/model-config.sh
- skills/setup-ralph/templates/scripts/classify-task.sh
- skills/setup-ralph/templates/scripts/capacity-monitor.sh
- skills/setup-ralph/templates/scripts/error-handler.sh
- skills/setup-ralph/templates/PROMPT_plan.md
- skills/setup-ralph/templates/PROMPT_build.md (existence confirmed via glob)
- skills/setup-ralph/templates/PROMPT_decompose.md (existence confirmed via glob)

### Subagent Work
None launched — all analysis performed inline.

### Next Step
DONE. See architecture-reference.md for reusable reference.
