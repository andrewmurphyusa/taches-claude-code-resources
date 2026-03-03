---
name: setup-ralph
description: Set up and configure the improved Ralph Wiggum autonomous coding loop in any directory — with orchestrator-based model routing, infrastructure error recovery, task decomposition, and backpressure.
---

<essential_principles>
## What is Ralph?

Ralph is Geoffrey Huntley's autonomous AI coding methodology that uses iterative loops with task selection, execution, and validation. In its purest form, it's a Bash loop:

```bash
while :; do cat PROMPT.md | claude ; done
```

The loop feeds a prompt file to Claude, the agent completes one task, updates the implementation plan, commits changes, then exits. The loop restarts immediately with fresh context.

### Core Philosophy

**The Ralph Wiggum Technique is deterministically bad in an undeterministic world.** Ralph solves context accumulation by starting each iteration with fresh context—the core insight behind Geoffrey's approach.

### Four Phases, Three Prompts, One Loop

1. **Planning Phase**: Gap analysis (specs vs code) outputs prioritized TODO list—no implementation, no commits (`./orchestrator.sh plan`)
2. **Decompose Phase** *(optional)*: Splits complex tasks into tier-annotated subtasks `[opus]`/`[sonnet]`/`[haiku]` before execution (`./orchestrator.sh decompose`)
3. **Building Phase**: Picks tasks from plan, selects model per task complexity, implements, runs tests (backpressure), commits (`./orchestrator.sh`)
4. **Observation Phase**: You sit on the loop, not in it—engineer the setup and environment that allows Ralph to succeed

### Key Principles

**Your Role**: Ralph does all the work, including deciding which planned work to implement next and how to implement it. Your job is to engineer the environment.

**Backpressure**: Create backpressure via tests, typechecks, lints, builds that reject invalid/unacceptable work. The orchestrator adds a second backpressure layer at the infrastructure level: rate limits, overload, and usage exhaustion are recovered automatically. Additionally, capacity monitoring proactively prevents capacity-based errors by sleeping when thresholds trigger.

**Observation**: Watch, especially early on. Prompts evolve through observed failure patterns.

**Context Efficiency**: With ~176K usable tokens from 200K window, allocating 40-60% to "smart zone" means tight tasks with one task per loop achieves maximum context utilization.

**File I/O as State**: The plan file persists between isolated loop executions, serving as deterministic shared state—no sophisticated orchestration needed.

**Dynamic Model Routing**: The orchestrator classifies each task and selects the cheapest capable model. Simple tasks (rename, reformat) use haiku; standard work uses sonnet; complex tasks (architect, debug, investigate) use opus. Annotate tasks explicitly with `[opus]`/`[sonnet]`/`[haiku]` to override.

**Stuck Escalation**: When the same task fails twice, the orchestrator automatically upgrades the model tier one step (haiku→sonnet→opus) before retrying. After max failures the task is skipped.

**Capacity Monitoring**: Before each iteration, the orchestrator proactively checks Claude OAuth capacity and sleeps if thresholds are triggered (5-hour window <5% or <20%, weekly window awareness). This prevents USAGE_EXHAUSTED errors in production loops and allows Ralph to gracefully pause during capacity-constrained periods.

**Remote Backup**: The loop automatically creates a private GitHub repo and pushes after each commit. This protects against accidental data loss from autonomous operations. Requires `gh` CLI authenticated. Disable with `RALPH_BACKUP=false`.

**Safety Rules**: PROMPT_build.md includes critical safety rules prohibiting dangerous operations like `rm -rf` on project directories. Tests must run in isolated temp directories.
</essential_principles>

<intake>
What would you like to do?

1. **Set up a new Ralph loop** - Initialize Ralph structure in a directory
2. **Understand Ralph concepts** - Learn about the technique and how it works
3. **Customize existing loop** - Modify prompts or configuration
4. **Troubleshoot Ralph** - Debug loop issues or improve performance

Wait for response before proceeding.
</intake>

<routing>
| Response | Workflow |
|----------|----------|
| 1, "set up", "setup", "new", "initialize", "create" | `workflows/setup-new-loop.md` |
| 2, "understand", "learn", "concepts", "explain", "how" | `workflows/understand-ralph.md` |
| 3, "customize", "modify", "change", "update", "edit" | `workflows/customize-loop.md` |
| 4, "troubleshoot", "debug", "fix", "problem", "issue" | `workflows/troubleshoot-loop.md` |
| Other | Clarify intent, then select appropriate workflow |

After reading the workflow, follow it exactly.
</routing>

<reference_index>
## Domain Knowledge

All in `references/`:

**Core Concepts:** ralph-fundamentals.md - Four phases, orchestrator layer, model routing, error recovery
**Structure:** project-structure.md - Required files including orchestrator.sh, scripts/, auth/
**Prompts:** prompt-design.md - Planning, building, and decompose mode instructions
**Backpressure:** validation-strategy.md - Tests, lints, builds, and infrastructure error recovery
**Best Practices:** operational-learnings.md - AGENTS.md guidance and evolution
</reference_index>

<workflows_index>
| Workflow | Purpose |
|----------|---------|
| setup-new-loop.md | Initialize Ralph structure in a directory |
| understand-ralph.md | Learn Ralph concepts and philosophy |
| customize-loop.md | Modify prompts or loop configuration |
| troubleshoot-loop.md | Debug loop issues and improve performance |
</workflows_index>

<success_criteria>
Skill is successful when:
- User understands which workflow they need
- Appropriate workflow loaded based on intent
- All required references loaded by workflow
- User can set up and run Ralph loops independently using orchestrator.sh
</success_criteria>
