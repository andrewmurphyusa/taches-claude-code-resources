# Plan: Proactive Capacity Monitoring for Ralph Orchestrator

## Input

Read the research output (`01-research.md` or prior context) before proceeding.
The plan must account for whatever data source the research found. If no direct
capacity API exists, the plan must specify the best available approximation approach.

## Context: What we are building

Add proactive capacity checking at the **start of each iteration** in the main
`while true` loop of `orchestrator.sh` (build mode only), so the orchestrator can
pause intelligently before hitting usage limits rather than reacting after failures.

### Codebase to understand before planning

Read these files in full:

- `skills/setup-ralph/templates/orchestrator.sh` — main orchestration loop
- `skills/setup-ralph/templates/scripts/error-handler.sh` — existing window tracking
  and recovery handlers (especially `mark_window_start`, `sleep_until_window_resets`,
  `reset_error_counters`, `cleanup_error_handler`)
- `skills/setup-ralph/templates/scripts/model-config.sh` — sourcing conventions
- `skills/setup-ralph/templates/scripts/classify-task.sh` — function interface patterns

### Key definitions

- **Work week**: Monday 06:00 to Friday 18:00 (local time)
- **Weekend**: Friday 18:00 to Monday 06:00 (local time)
- **Weekly reset time**: comes from actual capacity data, not hardcoded

## Feature specification (what to plan for)

### Capacity check trigger

The check runs at the top of the main `while true` loop in `orchestrator.sh`, **after**:
1. Stop-signal check (RALPH_STATUS.txt)
2. Iteration-limit check

And **before**:
3. Plan-file existence check
4. All-tasks-complete check
5. Task selection and model routing

### 5-hour limit rules

Given `pct_5h_remaining` = percentage of 5-hour usage window remaining:

```
if pct_5h_remaining < 5%:
    wait until 5-hour limit resets (exact reset time from capacity data)
    while sleeping:
        sleep at most 30 seconds at a time
        on each wake, re-read RALPH_STATUS.txt
        if status file signals exit → log message and exit cleanly
else if pct_5h_remaining < 20%:
    time_until_reset = seconds until 5-hour window resets
    sleep for time_until_reset / 3
    while sleeping in 30s increments:
        on each wake, re-read RALPH_STATUS.txt
        if exit signal → log and exit cleanly
```

### Weekly limit rules

Given `pct_weekly_remaining` = percentage of weekly usage limit remaining,
and `weekly_reset_epoch` = Unix timestamp when weekly limit resets:

```
if pct_weekly_remaining < 20%:
    if (current_time is during_work_week) OR (weekly_reset_epoch falls during_work_week):
        pause — wait until EITHER:
            - pct_weekly_remaining rises above 80% (limit has reset), OR
            - current_time crosses into weekend AND weekly_reset_epoch also falls in weekend
        while sleeping:
            sleep at most 30 seconds at a time
            on each wake, re-read RALPH_STATUS.txt
            if exit signal → log and exit cleanly
            re-query capacity data each wake cycle
```

No additional hard-stop threshold for weekly (< 20% is the only trigger).

### Multi-agent architecture

Design for extensibility — only implement Claude now, but make it trivial to add
Gemini, GPT-4, etc. later:

- **`scripts/capacity-claude.sh`** — Claude-specific capacity fetching
  - Exposes a standard function: `fetch_claude_capacity`
  - Populates standard variables:
    - `CAPACITY_5H_REMAINING_PCT` — integer 0-100
    - `CAPACITY_5H_RESET_EPOCH` — Unix timestamp of 5h reset (or -1 if unknown)
    - `CAPACITY_WEEKLY_REMAINING_PCT` — integer 0-100
    - `CAPACITY_WEEKLY_RESET_EPOCH` — Unix timestamp of weekly reset (or -1 if unknown)
  - Returns 0 on success, 1 on failure (capacity check skipped if fetch fails)

- **`scripts/capacity-monitor.sh`** — shared orchestration layer
  - Sources each agent's capacity script
  - Calls `fetch_<agent>_capacity` for each configured agent
  - Applies the 5-hour and weekly threshold rules
  - Handles all sleeping, status-file checking, and logging
  - Exposes: `check_all_agent_capacity` — called once per loop iteration
  - Agent list is configurable (default: just Claude)

### Logging

Each capacity check appends one line to `ralph.log`:
```
[CAPACITY] claude 5h=73% weekly=91% — OK
[CAPACITY] claude 5h=14% weekly=91% — waiting 1/3 of reset window (412s)
[CAPACITY] claude 5h=3% weekly=91% — waiting until 5h reset (1847s)
[CAPACITY] claude 5h=73% weekly=17% — work-week pause (weekly reset in weekend: skipping pause)
```

### What NOT to change

- No changes to `ralph.sh` behavior or interface
- No changes to existing `error-handler.sh` function signatures
- `orchestrator.sh` changes limited to: sourcing capacity-monitor.sh + one function call
  at the top of the main loop
- No new required env vars (all new vars are optional with safe defaults)
- macOS and Linux compatible (no `date -d`, use `date -v` on macOS or epoch arithmetic)

## Plan deliverable format

Produce a `<plan>` XML document:

```xml
<plan>
  <summary>
    2-3 sentence overview of the approach and any key decisions made based on research.
  </summary>

  <files>
    <file action="new|modify" path="relative/path/to/file.sh">
      <description>What this file does and why it changes</description>
      <changes>
        Bullet list of specific additions/modifications. Be concrete:
        - Function names to add
        - Exact location of orchestrator.sh integration (line range or surrounding code)
        - Variable names for the standard interface
        - Edge cases to handle
      </changes>
    </file>
    ...
  </files>

  <implementation_notes>
    Key technical decisions, cross-platform gotchas, and anything the implementer
    must be aware of that isn't obvious from the spec.
  </implementation_notes>

  <risks>
    What could go wrong, and how the implementation should guard against it.
    Include: what happens if capacity fetch fails, what if reset times are unavailable,
    what if the status file check during sleep fails.
  </risks>

  <verification_criteria>
    Concrete, testable checks to verify the implementation is correct:
    - How to manually test the 5-hour < 5% path
    - How to manually test the work-week weekly pause path
    - How to verify status-file exit during sleep works
    - How to verify a future agent can be added in < 10 lines
  </verification_criteria>
</plan>
```
