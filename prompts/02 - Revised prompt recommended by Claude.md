# Add `--plan-file` Parameter to Ralph Scripts

## Intent

Add a `--plan-file` parameter to the Ralph Wiggum scripts so that a custom implementation-plan file can be used instead of the hard-coded default (`IMPLEMENTATION_PLAN.md`). This allows plans and implementations to be kept in separate files.

**Topic identifier:** `ralph-plan-file-param`

---

## Context

**Project:** `taches-claude-code-resources`, branch `improved-ralph`  
**Location of files to change:** `skills/setup-ralph/templates/`

### What exists today

1. **`ralph.sh` line 44** — `PLAN_FILE="IMPLEMENTATION_PLAN.md"` hard-coded; the script reads/writes this file for task tracking and never accepts a file override from outside.

2. **`orchestrator.sh` lines 173–174** — `PLAN_FILE` and `PLAN_FILE_OUT` both default to `IMPLEMENTATION_PLAN.md`. `PLAN_FILE_OUT` is a separate variable only because the old `--from-plan`/`--to-plan` split allowed reading from one file and writing to another. The existing `--from-plan`, `--to-plan`, and `--with-plan` parameters (lines 434–521) will be **removed** and replaced by `--plan-file`, which always sets the same file for both reading and writing — so `PLAN_FILE_OUT` becomes redundant and will be eliminated.

3. **`PROMPT_build.md` lines 40, 78** — references `IMPLEMENTATION_PLAN.md` by name in instructions sent to Claude.

4. **`PROMPT_plan.md` lines 12, 23, 44** — references `IMPLEMENTATION_PLAN.md` by name.

5. **`PROMPT_decompose.md` lines 7, 11, 17, 22, 40, 88** — references `IMPLEMENTATION_PLAN.md` by name throughout.

### Known trade-off (do not try to solve)

- Using a custom plan file means Claude cannot automatically merge a sub-plan back into the overall `IMPLEMENTATION_PLAN.md`. This is an accepted limitation — document it in a comment or help text, do not design around it.
- `loop-docker.sh` (which also has `PLAN_FILE="IMPLEMENTATION_PLAN.md"`) is deprecated and should *not* receive the same treatment.

---

## Requirements

### 1. Add `--plan-file` to `ralph.sh`

- Accept `--plan-file FILE` as a new argument (alongside the existing `plan`, `--verbose`, `--model`).
- Set `PLAN_FILE` to the provided value; keep the default of `IMPLEMENTATION_PLAN.md` when the flag is absent.
- Update the usage/help text (around line 101) to document the new flag.
- Add `RALPH_PLAN_FILE` as an env-var fallback (lower priority than the CLI flag, higher priority than the hard-coded default), consistent with how `RALPH_MODEL` and `RALPH_MAX_STUCK` work.

### 2. Add `--plan-file` to `orchestrator.sh` and remove `--from-plan` / `--to-plan` / `--with-plan`

- Remove the `--from-plan`, `--to-plan`, and `--with-plan` argument-parsing branches (lines 434–521) and their associated variables (`ARG_FROM_PLAN`, `ARG_TO_PLAN`, `ARG_WITH_PLAN`).
- Eliminate `PLAN_FILE_OUT` entirely. Replace every reference to `PLAN_FILE_OUT` in the script (mtime checks in plan mode ~lines 697/743/746, mtime checks in decompose mode ~lines 814/855/858) with `PLAN_FILE`.
- Add `--plan-file FILE` as the single parameter: sets `PLAN_FILE` to the provided value. Default remains `IMPLEMENTATION_PLAN.md`.
- After resolving `PLAN_FILE`, export `RALPH_PLAN_FILE="$PLAN_FILE"` so that `ralph.sh` invocations inside the build loop (lines ~1098–1101), plan loop (lines ~706), and decompose loop (lines ~819) pick it up automatically.
- Update the help text (`print_help`) to document `--plan-file` and remove documentation of the three removed flags.

### 3. Substitute the plan filename into prompt files at runtime

The prompt files cannot use shell variables because they are piped directly to Claude. The fix is runtime substitution:

- Before piping any prompt file to Claude, `ralph.sh` (and the orchestrator's decompose path) should write a temporary copy of the prompt with `IMPLEMENTATION_PLAN.md` replaced by the value of `$PLAN_FILE`.
- Use `sed` for the substitution (already present in both files as `sed_i`). Create a temp file, substitute, pipe, then delete the temp file.
- Apply this to `PROMPT_build.md`, `PROMPT_plan.md`, and `PROMPT_decompose.md`.
- Ensure the original prompt template files are never modified — only temp copies.

### 4. Update help text, error messages, and status messages

- Any place where `IMPLEMENTATION_PLAN.md` appears as a literal string in an echo/error message (e.g. orchestrator.sh line 1008, ralph.sh lines 451–454) should use `$PLAN_FILE` instead, so error messages reflect the actual file being used.

---

## Success criteria

- `./orchestrator.sh --plan-file MY_PLAN.md` reads tasks from and writes to `MY_PLAN.md`.
- `./ralph.sh --plan-file MY_PLAN.md` reads/marks tasks in `MY_PLAN.md` and prompts Claude with `MY_PLAN.md` instead of `IMPLEMENTATION_PLAN.md`.
- `./orchestrator.sh` with no `--plan-file` flag behaves exactly as before (no regression).
- `./ralph.sh` with no `--plan-file` flag behaves exactly as before.
- The original `PROMPT_build.md`, `PROMPT_plan.md`, and `PROMPT_decompose.md` template files are unchanged on disk.
- The `RALPH_PLAN_FILE` env var (without any CLI flag) also overrides the default.

---

## Pipeline specification

**Research phase** — investigate:
- Whether any other shell variables in `ralph.sh` or `orchestrator.sh` depend on the plan filename (e.g. stuck-tracker, mtime checks, report generation).
- Whether the `@IMPLEMENTATION_PLAN.md` syntax used in `PROMPT_plan.md` line 12 (`Study @IMPLEMENTATION_PLAN.md`) requires special handling in the sed substitution.

**Research outcomes**

- **Q1 — Other variables depending on plan filename:**
  - `ralph.sh`: `PLAN_FILE` is the sole variable; used in `check_all_tasks_complete()`, `get_current_task()`, `generate_report()`, and the build-mode existence check (~line 450). The stuck tracker (`STUCK_FILE`) does NOT reference the plan filename.
  - `orchestrator.sh`: `PLAN_FILE` used in `get_current_task()`, `check_all_tasks_complete()`, and the line-1008 error message. `PLAN_FILE_OUT` is used *only* for mtime checks in plan mode (lines ~697, 743, 746) and decompose mode (lines ~814, 855, 858) — nowhere else. Once `PLAN_FILE_OUT` is eliminated, those mtime checks use `PLAN_FILE` directly.
  - `loop-docker.sh`: has its own `PLAN_FILE="IMPLEMENTATION_PLAN.md"` (line 26) used in `check_complete()` — but this file is confirmed deprecated (see Q4).

- **Q2 — `@IMPLEMENTATION_PLAN.md` sed escaping:**
  - The `@` character is NOT special in a sed pattern. It only acts as a delimiter when placed immediately after `s` (e.g., `s@…@…@`). Inside a `/…/` pattern it is literal and needs no escaping.
  - However, if `$PLAN_FILE` contains `/` characters (e.g., a relative path like `subdir/MY_PLAN.md`), using `/` as the sed delimiter will break the substitution. Use a different delimiter — e.g., `|` or `#` — for safety: `sed "s|IMPLEMENTATION_PLAN\.md|$PLAN_FILE|g"`.

- **Q3 — Complete list of `IMPLEMENTATION_PLAN.md` occurrences in `skills/setup-ralph/templates/`:**
  - **Actionable (require code/template changes):**
    - `ralph.sh` line 44 — variable default
    - `orchestrator.sh` lines 173, 174 — variable defaults; lines 225, 238, 239, 244 — help text; line 1008 — error message
    - `PROMPT_build.md` lines 40, 78
    - `PROMPT_plan.md` lines 12, 23, 44
    - `PROMPT_decompose.md` lines 7, 11, 17, 22, 40, 88
    - `loop-docker.sh` line 26 — excluded (deprecated)
  - **Reference docs (low-priority, update if desired):**
    - `.reference/session-state.md` lines 30, 33, 34
    - `.reference/architecture-reference.md` lines 9, 24, 37, 81, 95, 108, 122
  - **Comment-only (no functional impact):**
    - `scripts/classify-task.sh` line 3 — a comment string, no runtime effect

- **Q4 — Is `loop-docker.sh` deprecated?**
  - Confirmed deprecated. It is a standalone script with no integration into the current orchestration flow. `orchestrator.sh` only delegates to `ralph.sh`. No skill setup file references `loop-docker.sh`. The implementation should exclude it.

**Plan phase** — decide:
- Exact CLI flag names and env var precedence.
- Whether temp prompt files should go to `/tmp` or a `.ralph-tmp/` dir in the project.

**Plan decisions** - document plan-phase decisions here.

**Implementation phase** — build in this order:
1. `ralph.sh`: add `--plan-file` / `RALPH_PLAN_FILE`, update `PLAN_FILE` variable, update help text.
2. `ralph.sh`: add prompt-file temp-copy substitution before Claude invocation.
3. `orchestrator.sh`: remove `--from-plan`/`--to-plan`/`--with-plan`, add `--plan-file`, export `RALPH_PLAN_FILE` to child invocations.
4. `orchestrator.sh` / `ralph.sh`: replace hard-coded `IMPLEMENTATION_PLAN.md` in echo/error strings with variable references.
5. `loop-docker.sh`: apply same `--plan-file` / `RALPH_PLAN_FILE` treatment if confirmed in research phase.
6. Update any relevant `.reference/` docs in `skills/setup-ralph/templates/.reference/`.

---

## EXECUTION RULES

- Do ONE step only: research, or plan, or 1 implementation step.
- Mark it [~] before, [x] after
- Resume from first [ ] or [~]
- Never redo [x]
- Stop after one step

---

## Commands to run next

### 1. Generate the meta-prompt pipeline

```
cd "c:/sourcecode/github/taches-claude-code-resources"
```

Then invoke the create-meta-prompts skill:

```
/voodoobunny-fork-of-taches-cc-resources:create-meta-prompts
```

Paste or reference this file as context when prompted.

### 2. Review the generated prompts

Check the `.prompts/` directory for the generated research, plan, and implement prompts.

### 3. Run the implementation loop

```
cd "c:/sourcecode/github/taches-claude-code-resources"
./skills/setup-ralph/templates/orchestrator.sh plan
```
