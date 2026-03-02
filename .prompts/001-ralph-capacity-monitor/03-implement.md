# Implement: Proactive Capacity Monitoring for Ralph Orchestrator

## Input

Read the research output and plan output (prior context) before writing any code.
Implement exactly what the plan specifies. Do not add features beyond the plan.

## Repository context

Working directory: `skills/setup-ralph/templates/`

Files to modify or create:
- `orchestrator.sh` — add capacity check call at top of main build loop
- `scripts/capacity-claude.sh` — NEW: Claude-specific capacity fetching
- `scripts/capacity-monitor.sh` — NEW: shared multi-agent orchestration layer

Read ALL of these files before writing any code:
- `orchestrator.sh`
- `scripts/error-handler.sh`
- `scripts/model-config.sh`
- `scripts/classify-task.sh`
- `scripts/stuck-tracker.sh`

Understand the existing conventions (function naming, variable naming, comment style,
error handling patterns) and follow them exactly in new code.

## Implementation rules

### Bash constraints

- Bash only — no Python, no Node, no awk one-liners beyond simple field extraction
- All arithmetic via `$(( ))` — no `bc`, no `expr`
- Cross-platform `date` handling:
  - Never use `date -d` (Linux-only)
  - Use epoch arithmetic: `$(date +%s)` gives current epoch on both platforms
  - For converting a timestamp TO epoch from a string, use Python as a last resort
    only if no pure-bash alternative exists; prefer formats that can be parsed
    with epoch arithmetic alone
- Status file check during sleep must use the same pattern as the existing stop-signal
  check in `orchestrator.sh` (grep for BREAK|INTERRUPT|STOP)

### Capacity fetch failure handling

If `fetch_claude_capacity` fails (network error, API unavailable, CLI command not found):
- Set all capacity percentages to 100 (assume full capacity — proceed normally)
- Log the failure to `ralph.log` with `[CAPACITY] claude fetch failed — assuming full capacity`
- Return 1 from the fetch function
- `check_all_agent_capacity` must handle return code 1 gracefully (continue loop)
- Never abort the orchestrator loop due to a capacity fetch failure

### Status-file exit during sleep

When sleeping in 30-second increments (during any capacity wait), after each `sleep 30`:

```bash
if [ -f "$STATUS_FILE" ] && grep -qiE 'BREAK|INTERRUPT|STOP' "$STATUS_FILE" 2>/dev/null; then
  echo "[CAPACITY] Exit signal detected during capacity wait — stopping." | tee -a "$LOG_FILE"
  exit 0
fi
```

This must be present in EVERY sleep loop — both the 5-hour wait loops and the weekly
wait loop.

### Logging format

All capacity log lines must use this exact prefix for greppability:
```
[CAPACITY] <agent> ...message...
```

Append to `$LOG_FILE` (defined in orchestrator.sh) AND echo to stdout. Use `tee -a`:
```bash
echo "[CAPACITY] claude 5h=73% weekly=91% — OK" | tee -a "$LOG_FILE"
```

### orchestrator.sh integration

Source the new scripts alongside the existing helpers at the top of the file:
```bash
source "$ORCHESTRATOR_DIR/scripts/capacity-monitor.sh"
```

Call the capacity check exactly once per build-mode iteration, after the stop-signal
check and iteration-limit check, before any plan/task logic:
```bash
# Check agent capacity before each iteration
check_all_agent_capacity
```

Do not add capacity checking to plan mode or decompose mode.

### Standard interface contract

`scripts/capacity-claude.sh` must expose `fetch_claude_capacity` which:
1. Calls whatever data source the research found
2. Sets (in the calling shell's environment via `export` or direct assignment):
   - `CAPACITY_5H_REMAINING_PCT` — integer 0–100 (100 = full, 0 = exhausted)
   - `CAPACITY_5H_RESET_EPOCH` — Unix epoch integer (-1 if unavailable)
   - `CAPACITY_WEEKLY_REMAINING_PCT` — integer 0–100
   - `CAPACITY_WEEKLY_RESET_EPOCH` — Unix epoch integer (-1 if unavailable)
3. Returns 0 on success, 1 on failure

`scripts/capacity-monitor.sh` must expose `check_all_agent_capacity` which:
1. Iterates over `CAPACITY_AGENTS` array (default: `("claude")`)
2. For each agent, sources `scripts/capacity-${agent}.sh` and calls
   `fetch_${agent}_capacity`
3. Applies the threshold rules from the spec
4. Returns 0 always (never aborts the caller)

To add a future agent (e.g. Gemini), the only change needed is:
- Create `scripts/capacity-gemini.sh` with `fetch_gemini_capacity`
- Add `"gemini"` to `CAPACITY_AGENTS`

### Work-week / weekend helper functions

Add these to `scripts/capacity-monitor.sh`:

```bash
# is_work_week — returns 0 (true) if current local time is Mon 06:00 – Fri 18:00
is_work_week() { ... }

# epoch_is_work_week <epoch> — returns 0 if the given epoch falls in a work week
epoch_is_work_week() { local ts="$1"; ... }
```

Use `date +%u` (1=Mon … 7=Sun) and `date +%H%M` for time-of-day comparisons.
Both are POSIX-compatible.

## Verification steps

After implementing, verify:

1. **Syntax check**: `bash -n scripts/capacity-claude.sh && bash -n scripts/capacity-monitor.sh && bash -n orchestrator.sh`

2. **Dry-run 5h < 5% path**: Temporarily override `CAPACITY_5H_REMAINING_PCT=2` after
   the fetch call, run `orchestrator.sh 1` (1 iteration), confirm it sleeps in 30s
   increments and exits if `RALPH_STATUS.txt` contains `STOP`.

3. **Dry-run weekly pause path**: Override `CAPACITY_WEEKLY_REMAINING_PCT=15` and set
   system time to a weekday (or hardcode `is_work_week` to return true in test), confirm
   the orchestrator waits and re-queries each cycle.

4. **Status-file exit during sleep**: While orchestrator is sleeping in a capacity wait,
   write `STOP` to `RALPH_STATUS.txt` and confirm it exits within 30 seconds.

5. **Fetch failure graceful handling**: Remove or break the fetch command temporarily,
   confirm the orchestrator continues normally and logs the failure.

6. **No existing tests broken**: `bash -n orchestrator.sh` passes; all existing
   `error-handler.sh` functions remain callable with unchanged signatures.

## Commit

When the implementation is complete and verified:

```
git add skills/setup-ralph/templates/orchestrator.sh \
        skills/setup-ralph/templates/scripts/capacity-claude.sh \
        skills/setup-ralph/templates/scripts/capacity-monitor.sh

git commit -m "feat(ralph): add proactive capacity monitoring to orchestrator

Check 5-hour and weekly Claude usage limits at start of each loop iteration.
Pauses autonomously when approaching limits, respects work-week / weekend
schedule for weekly pauses, sleeps in 30s increments with status-file exit.
Multi-agent abstraction: scripts/capacity-{agent}.sh per coding agent."
```
