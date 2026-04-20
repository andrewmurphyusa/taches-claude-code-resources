# Ralph Loop Architecture Reference

Generated: 2026-04-02 | Source: skills/setup-ralph/templates/

---

## System Overview

Three modes: **plan** (generate IMPLEMENTATION_PLAN.md, configurable via `--plan-file FILE` or `RALPH_PLAN_FILE` env var), **decompose** (split complex tasks), **build** (execute tasks). Entry is always via `orchestrator.sh`; build/plan execution is delegated to `ralph.sh`.

---

## Execution Flow

### Plan Mode (`./orchestrator.sh plan`)

1. orchestrator.sh parses `plan` → STAGE="plan"
2. Sources: `scripts/model-config.sh`, `scripts/classify-task.sh`, `scripts/error-handler.sh`
3. Loads optional auth from `auth/*.sh` and `auth/engines-config.json`
4. Sources `scripts/capacity-monitor.sh` (after CLI overrides applied)
5. Sets STATUS_FILE="RUNNING", saves/rotates `ralph.log` → `ralph.accumulated.log`
6. Plan loop (max=RALPH_PLAN_MAX_ITERATIONS, default 5):
   a. Checks STATUS_FILE for BREAK/INTERRUPT/STOP
   b. Snapshots `IMPLEMENTATION_PLAN.md` mtime
   c. Calls `bash ralph.sh plan 1 --model opus` (limit=1 enforces single-call contract)
   d. On exit≠0: classifies error → retries or exits
   e. Compares mtime before/after → if unchanged, exits as "planning complete"
7. ralph.sh (invoked with `plan 1 --model opus`):
   a. Sets MODE="plan", LIMIT=1, PROMPT_FILE="PROMPT_plan.md"
   b. Sources `scripts/stuck-tracker.sh`, `scripts/capacity-monitor.sh`
   c. Builds CLAUDE_ARGS: `--model opus -p --dangerously-skip-permissions --output-format text`
   d. Calls: `cat PROMPT_plan.md | claude [CLAUDE_ARGS] 2>&1 | tee -a ralph.log`
   e. After 1 iteration (LIMIT=1), exits naturally

### Build Mode (`./orchestrator.sh`)

1. orchestrator.sh build loop: reads task from IMPLEMENTATION_PLAN.md, classifies → model/engine
2. Writes task to NEXT-TASK.md; calls `bash ralph.sh 1 --model <tier>`
3. ralph.sh: MODE="build", sources PROMPT_build.md, invokes claude with task context
4. On success: update stuck tracker, push to backup, continue

---

## Components

### orchestrator.sh
- Argument parsing and validation (plan/decompose/build, --stage, --limit, --model, etc.)
- Auth loading (`auth/*.sh`, `auth/engines-config.json`)
- Capacity threshold override exports (CLI flags → env vars → capacity-monitor.sh)
- Plan stage: mtime-based done detection, error classification + retry
- Build stage: task reading, model/engine routing, multi-engine fallback (secondary/tertiary), stuck escalation
- NEXT-TASK.md write (communicates selected task to ralph.sh/claude)
- `invoke_engine()`: dispatches to ralph.sh (claude), `codex exec`, or `gemini -p` (multi-engine)

### ralph.sh
- Receives plan/build MODE from positional arg
- Selects PROMPT_FILE based on MODE
- OAuth token loading from `~/.claude-oauth-token`
- Iterates: STATUS_FILE check → capacity check → claude invocation → iteration summary
- Stuck detection (build mode only): delegates to stuck-tracker.sh
- Cleanup: generates REPORT.md (build only); removes .ralph_stuck_tracker, NEXT-TASK.md (unless RALPH_ORCHESTRATED=true)
- Remote backup: git push after each successful build iteration

### scripts/

| File | Role |
|------|------|
| `model-config.sh` | Model tier constants; per-engine model IDs; `get_model_for_tier()`, `validate_model()`, `upgrade_tier()` |
| `classify-task.sh` | `classify_task()` → haiku/sonnet/opus (single) or ranked 3-tuple (multi-engine); `should_decompose()`; `strip_tier_annotation()` |
| `stuck-tracker.sh` | `init/update/is_stuck/skip_stuck_task()`; persists to `.ralph_stuck_tracker` file |
| `capacity-monitor.sh` | `check_all_agent_capacity()`; sources per-engine capacity-*.sh; 5h and weekly threshold rules with sleep |
| `capacity-claude.sh` | Fetches Claude capacity (5h remaining %, reset epoch, weekly %) |
| `capacity-codex.sh` | Fetches Codex capacity via `/tmp/ralph-codex-reset.epoch` |
| `capacity-gemini.sh` | Fetches Gemini capacity via `/tmp/ralph-gemini-reset.epoch` |
| `error-handler.sh` | `classify_error()` (5 types); rate-limit backoff; overloaded retry; window tracking; `estimate_prompt_tokens()` |

### PROMPT files

| File | Mode | Role |
|------|------|------|
| `PROMPT_plan.md` | plan | Instructs claude to read specs/*, study existing IMPLEMENTATION_PLAN.md, run gap analysis, write/update plan |
| `PROMPT_build.md` | build | Instructs claude to read NEXT-TASK.md, implement the task, commit |
| `PROMPT_decompose.md` | decompose | Instructs claude to split complex tasks into tier-annotated subtasks |

---

## Data Flow

```
CLI args
  → orchestrator.sh (model routing, task selection)
    → NEXT-TASK.md (task communicated to claude)
    → ralph.sh (PROMPT_FILE selection, claude invocation)
      → claude CLI (reads prompt, reads/writes project files)
        → IMPLEMENTATION_PLAN.md (written/updated by claude)
        → source files (read/written by claude per prompt instructions)
      → ralph.log (tee of combined stdout+stderr)
  → REPORT.md (build mode only, generated at exit)
  → RALPH_STATUS.txt (stop signal channel)
```

---

## File Contracts

| File | Written by | Read by | Behavior |
|------|-----------|---------|---------|
| `IMPLEMENTATION_PLAN.md` | claude (via PROMPT_plan.md) | orchestrator.sh (mtime check, task extraction), ralph.sh (task extraction, stuck skip) | If exists: claude updates/merges. If missing: claude creates. Orchestrator detects completion via mtime stability. |
| `NEXT-TASK.md` | orchestrator.sh (build mode), ralph.sh standalone (build mode) | claude (via PROMPT_build.md) | Written before each build iteration; removed on exit (unless RALPH_ORCHESTRATED=true) |
| `RALPH_STATUS.txt` | orchestrator.sh ("RUNNING" on start), user ("STOP"/"BREAK") | ralph.sh, orchestrator.sh (every iteration) | Stop signal: any content matching BREAK/INTERRUPT/STOP triggers clean exit |
| `ralph.log` | ralph.sh (tee), orchestrator.sh | user (tail -f) | Rotated to ralph.accumulated.log at session start |
| `.ralph_stuck_tracker` | stuck-tracker.sh | stuck-tracker.sh | Persists LAST_TASK, STUCK_COUNT, CURRENT_MODEL_TIER, CURRENT_ENGINE across iterations |
| `.ralph_window_start` | error-handler.sh | error-handler.sh | Tracks 5h usage window start epoch; removed after window reset |
| `REPORT.md` | ralph.sh generate_report() | user | Build mode only; summary of session metrics and task counts |

---

## Control Points

| Location | Controls | Risk |
|----------|---------|------|
| `PROMPT_plan.md` (entire file) | All planning behavior: what claude reads, what it writes, format of IMPLEMENTATION_PLAN.md | Medium — changing this changes all plan output |
| `orchestrator.sh:519-616` | Plan entry: model selection, max iterations (RALPH_PLAN_MAX_ITERATIONS), done detection | Medium |
| `orchestrator.sh:556-609` | Done detection logic: mtime comparison | Low — well-isolated |
| `ralph.sh:456-479` | Prompt file selection per mode | Low — straightforward swap |
| `ralph.sh:482` | CLAUDE_ARGS: model, permissions, output format | Medium — affects all claude calls |
| `ralph.sh:579` | Actual claude invocation | High — core execution path |
| `scripts/classify-task.sh:_classify_task_single` | Model tier routing heuristics | Low for build mode only |
| `RALPH_PLAN_MAX_ITERATIONS` (env var) | Max plan iterations before forced exit | Low |

---

## Known Constraints

- **Configurable plan file**: The plan filename defaults to `IMPLEMENTATION_PLAN.md` and can be overridden via `--plan-file FILE` CLI flag or `RALPH_PLAN_FILE` env var. Both orchestrator.sh and ralph.sh honour the override; mtime-based done detection uses the resolved filename.
- **PROMPT_plan.md assumes project structure**: References `specs/*`, `src/lib/*`, `src/*` — will silently find nothing if absent.
- **Plan mode LIMIT hardcoded to 1 per orchestrator call**: orchestrator.sh passes `"plan" "1"` to ralph.sh; the outer plan loop retries up to RALPH_PLAN_MAX_ITERATIONS.
- **macOS/Linux path split**: `sed -i` wrapper (`sed_i`) required; `stat` flags differ. Both handled via OSTYPE checks.
- **Multi-engine disabled by default**: RALPH_MULTI_ENGINE=false; all routing goes to Claude unless explicitly enabled.
- **Plan mode does not use NEXT-TASK.md**: It's a build-mode construct only.
- **OAuth token path hardcoded**: `~/.claude-oauth-token` — no CLI override.

---

## Dead Zones (plan mode)

- `stuck-tracker.sh` sourced unconditionally in ralph.sh but all its functions are unused in plan mode
- `init_stuck_tracker` only called in build mode (`else` branch at ralph.sh:471)
- `check_all_tasks_complete` and `get_current_task` defined in ralph.sh but never called in plan mode
- `push_to_backup`, `print_iteration_summary`, `generate_report` all gated on `MODE=build`
- `REPORT.md` never written in plan mode
- `NEXT-TASK.md` never written by orchestrator in plan mode
- `decompose` stage in orchestrator.sh is a completely separate one-shot path with no loop
