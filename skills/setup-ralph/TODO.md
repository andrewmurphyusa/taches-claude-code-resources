# Improvements to make to Ralph:

## 1. [FIXED] Fix bug: plan mode (and maybe decompose mode) not ending when no further changes are required.

- Plan mode doesn't stop when no further planning is required (once, when it ran out of capacity, it looped nearly 1000 times).  
- make it stop if it detects "no further changes are required" already in the plan file
- make it stop when it determines that no further changes are required.

- check decompose mode for the same bug, and add stop conditions there if necessary

## 2. [FIXED] Fix bug: decompose mode doesn't log to ralph.log?

Running "tail -f ralph.log", ran decompose, it decomposed tasks but nothing was logged to ralph.log!

## 3. [FIXED] Fix bug: the task it *says* it's doing next/now isn't what it actually *picks to do* 

- This one is a bit bigger to fix, because it requires identifying the actual next task to work on in a separate place from the step that actually picks the next task, using the same logic.  It might be better to have it create a separate "NEXT-TASK.md" file, and populate that file from the orchestrator and pick it up in the ralph script
- this may be partially fixed ("NEXT_TASK.md") but I am not convinced that the prompt in @`templates/PROMPT-BUILD` actually considers that file *at all*.

## 4. [FIXED] Add iteration limits to plan and decompose modes.

- plan & decompose modes currently do not have any iteration limiting
- have them respect the iteration limits

## 5. [FIXED] Could - remove iterations from ralph.sh entirely since it doesn't actually do them any more.

## 6. [FIXED] Add "--stop-after" parameter(s)

- add parameter(s) to limit the *clock time* that iterations will run until.
- either have one parameter "--stop-after" which is a time OR a date-and-time
-- or have "--stop-after-date" and "--stop-after-time" which are date & time respectively, and have it combine those 2 parameters to set the complete stop time
-- if only time is provided, then check whether the script start time is after that time
    - if no, then use the current date for the stop date
    - if yes, then use tomorrow for the stop date
- absolute stop time is stop-date + stop-time
- at start of each iteration, check whether the current date+time is after the stop date+time
    - if yes then break out of iteration loop and stop

## 7. [FIXED] Remove references to Claude-specific models from `PROMPT_build.md`

- the Build phase may run against Claude Code, Codex, or Gemini.  The build prompt needs to avoid making assumptions about the build engine
- might necessitate separate `PROMPT_build.md` files for each engine type
- also need to make sure that it doesn't force Claude into using Sonnet where the plan has determined that it should use Opus or Haiku.

## 8. Make Ralph skip git branch & commit

- right now, if there are any issues with git in the project-specific branch (like with Buckaroo), the whole of Ralph fails.
- have a way to turn of gitting and committing
- start with environment variable, then add parameter
- ... there is an environment variable already, I just can't figure out how to set it to "false"...

## 9. [FIXED] Separate "Stuck" from "Has Sub-tasks" statuses in implementation-plan

- right now both "Stuck" and "Has sub-tasks" are indicated by the letter "S" in the task checkbox in the implementation plan.
- change the letter used for "Has Sub-tasks" - maybe "P" for "Parent"?
- also add logic that parent tasks are complete when all their child tasks are complete

## 10. Fix: `double stuck-count increment` bug

- orchestrator.sh:1013 calls `update_stuck_tracker "$current_task"`, writes `.ralph_stuck_tracker` with incremented count. Then ralph.sh is invoked, calls `init_stuck_tracker` (reads the same file) at ralph.sh:457, then calls `update_stuck_tracker "$current_task"` again at ralph.sh:518–519. Since `current_task == LAST_TASK`, the count increments a second time.
- Result: with `MAX_STUCK=3`, a task is skipped after only **2 real failures** — orchestrator sees `STUCK_COUNT=3` on the 2nd iteration's ralph.sh return because count went 1 → 2 → 3 across two invocations.

## 11. Fix: `{{VALIDATION_COMMANDS}}` placeholder never substituted

- [PROMPT_build.md:71] `- Run: {{VALIDATION_COMMANDS}}`
- Neither orchestrator.sh nor ralph.sh performs any substitution before piping `PROMPT_build.md` to Claude (ralph.sh:539 uses raw `cat`). Claude receives the literal string `{{VALIDATION_COMMANDS}}`. Claude may handle this gracefully via heuristics, but per design intent it should receive actual commands such as `npm test` or `pytest`.
- there is a footer in each plan section with "validation:".
    - parse this with a small model to resolve what validation commands to use?

## 12. Fix: Ralph.sh model-tier validation limited to Claude models

- in `ralph.sh`: `validate_model()` (lines 32-41) only check against Claude models
- this should be multi-engine-aware and engine-specific

