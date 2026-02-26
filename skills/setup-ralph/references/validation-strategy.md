# Validation Strategy

Using tests, lints, builds, and infrastructure error recovery to steer Ralph.

<what_is_backpressure>
## What is Backpressure?

Backpressure is automated validation that rejects invalid work. It creates a self-correcting feedback loop:

1. Ralph implements task
2. Validation runs (tests, type checks, lints)
3. If validation fails, Ralph investigates and fixes
4. Loop continues until validation passes
5. Only then can Ralph commit and move to next task

**Without backpressure:** Ralph generates code that may not work, accumulates errors, goes off track.

**With backpressure:** Ralph must produce working code to progress. Quality is enforced, not hoped for.

There are two levels of backpressure:
- **Code-level:** Tests, type checks, lints, builds — enforced inside the Claude prompt
- **Infrastructure-level:** API error recovery — enforced by the orchestrator outside the prompt
</what_is_backpressure>

<types_of_backpressure>
## Types of Backpressure

### 1. Tests (Most Important)

**Unit tests:** Verify individual functions/components
**Integration tests:** Verify components work together
**End-to-end tests:** Verify full user workflows

**Why tests are critical:**
- Binary pass/fail (no ambiguity)
- Fast feedback (run every iteration)
- Specific to requirements (aligned with specs)
- Self-documenting (show expected behavior)

**If no tests exist:**
Ralph should create them as part of implementation. Update building prompt:

```markdown
3. Implement
   - Write the functionality
   - Add tests for new functionality
   - Ensure tests pass
```

### 2. Type Checking

**TypeScript:** `tsc --noEmit` or `npm run type-check`
**Python:** `mypy .`
**Go:** Built into `go build`
**Rust:** Built into `cargo build`

**Benefits:**
- Catches type errors before runtime
- Enforces interface contracts
- Prevents common bugs

**Limitation:**
- Types can be correct but logic wrong
- Needs tests for behavior validation

### 3. Linting

**JavaScript/TypeScript:** ESLint, Biome
**Python:** Ruff, flake8, pylint
**Go:** golangci-lint
**Rust:** clippy

**Benefits:**
- Enforces code style
- Catches common mistakes
- Maintains consistency

**Limitation:**
- Style != correctness
- Can be overly strict
- May slow down loop if too many rules

**Recommendation:** Start with minimal linting, add rules as patterns emerge.

### 4. Builds

**Compiled languages:** Ensure code compiles
**Bundlers:** Ensure assets bundle correctly
**Docker:** Ensure containers build

**Benefits:**
- Catches syntax errors
- Verifies dependencies
- Confirms deployment readiness

**Limitation:**
- Build success != working software
- Slower than tests (use sparingly in loop)

### 5. Custom Validation

**Example: Visual regression tests**
- Screenshot comparison
- LLM-as-judge for subjective criteria

**Example: Performance benchmarks**
- Response time thresholds
- Memory usage limits

**Example: Security scans**
- Dependency vulnerability checks
- Static analysis for common issues

**When to use:**
- Project-specific quality criteria
- Subjective acceptance criteria
- Non-functional requirements
</types_of_backpressure>

<infrastructure_error_recovery>
## Infrastructure Error Recovery

The orchestrator (`orchestrator.sh`) provides a second backpressure layer at the API level. When `loop.sh` exits with a non-zero code, the orchestrator classifies the error and applies the appropriate recovery strategy — without requiring manual intervention.

### Error Types and Recovery

**RATE_LIMIT** (HTTP 429 or `rate_limit_error`)
- Exponential backoff: 1s → 2s → 4s → 8s → 16s → 32s → 60s (cap)
- Each delay has ±20% jitter to avoid thundering herd
- After 5 consecutive rate-limit failures: escalates to usage window sleep
- The same task is retried after recovery

**OVERLOADED** (`overloaded_error`)
- Fixed 45s sleep, up to 3 retries
- After 3 overloaded failures: escalates to rate limit treatment
- The same task is retried after recovery

**USAGE_EXHAUSTED** ("usage limit" or "5-hour window")
- Computes remaining time from when the first successful iteration was recorded
- Sleeps exactly until the 5-hour window resets (plus 5-minute buffer)
- The same task is retried after the window resets
- State file: `.ralph_window_start` (cleaned up on reset)

**CONTEXT_TOO_LONG** (`context_length_exceeded`)
- Task is automatically skipped (marked `[S]` in the plan)
- Adds the task to the `## Blocked` section in `IMPLEMENTATION_PLAN.md`
- Loop continues with the next task

**AUTH_FAILURE** (`authentication_error`)
- Loop stops immediately
- Requires manual intervention (re-authenticate, check token)

**UNKNOWN** (any other non-zero exit)
- Exit code is propagated — loop stops
- Investigate `ralph.log` for details

### Pre-flight Token Estimation

Before each iteration, the orchestrator estimates the prompt token count (`wc -w × 1.4`). If the estimate exceeds 150,000 tokens, a warning is logged. The iteration still runs — this is informational only.

### Stuck Detection and Tier Escalation

The orchestrator tracks per-task failure counts independently of error type:

1. **First failure:** Task is retried (with any error recovery applied)
2. **Second failure (STUCK_COUNT ≥ 2):** Model tier is automatically upgraded one step (haiku→sonnet, sonnet→opus) for the next attempt
3. **Third failure (STUCK_COUNT ≥ MAX_STUCK):** Task is skipped — marked `[S]`, added to `## Blocked`

`RALPH_MAX_STUCK` environment variable controls the threshold (default: 3).

This escalation happens silently during the loop. If you observe a task consuming opus when it started as haiku, the orchestrator escalated it due to repeated failures.
</infrastructure_error_recovery>

<validation_levels>
## Validation Levels

Choose based on project maturity and speed needs:

### Level 1: Tests Only (Fastest)
```markdown
Run: npm test
```

**When to use:**
- Early development
- Fast iteration needed
- No type system or linting configured

**Pros:** Fast loop, minimal friction
**Cons:** May accumulate style inconsistencies

### Level 2: Tests + Type Checking (Recommended)
```markdown
Run:
- npm test
- npm run type-check
```

**When to use:**
- TypeScript/typed projects
- After initial implementation phase
- When interfaces are stabilizing

**Pros:** Good balance of speed and quality
**Cons:** Type errors can slow down loop

### Level 3: Full Validation (Slowest)
```markdown
Run:
- npm test
- npm run type-check
- npm run lint
- npm run build
```

**When to use:**
- Mature projects
- Pre-release quality gates
- When consistency is critical

**Pros:** Highest quality output
**Cons:** Slowest loop, most friction

### Level 4: Custom Validation
```markdown
Run:
- npm test
- npm run type-check
- npm run visual-test
- npm run security-scan
```

**When to use:**
- Specific quality requirements
- Regulated industries
- User-facing products

**Pros:** Tailored to actual needs
**Cons:** Complex to set up and maintain
</validation_levels>

<validation_in_prompts>
## Validation in Prompts

### Planning Mode

No validation needed. Planning mode doesn't change code.

### Decompose Mode

No validation needed. Decompose mode only modifies `IMPLEMENTATION_PLAN.md`.

### Building Mode

Include validation as a required step:

```markdown
4. Validate
   - Run: [specific commands]
   - Use only 1 Sonnet subagent for build/tests
   - If validation fails, investigate and fix
   - Do not commit until all validation passes
   - If repeatedly failing (3+ attempts), note blocker and move on
```

**Key points:**
- Specific commands (not vague "make sure it works")
- Single subagent for validation (creates backpressure bottleneck)
- Failure requires investigation and fix
- Escape hatch for stuck tasks (note blocker, move on)
</validation_in_prompts>

<handling_validation_failures>
## Handling Validation Failures

### Expected Behavior

Ralph should:
1. See validation failure
2. Read error messages
3. Investigate cause
4. Fix the issue
5. Re-run validation
6. Repeat until passing

### Failure Patterns

**Pattern 1: Test failure due to incorrect implementation**
- Ralph implemented wrong behavior
- Fix: Update implementation to match spec

**Pattern 2: Test failure due to incorrect test**
- Spec changed but test didn't
- Fix: Update test to match current spec

**Pattern 3: Type error due to API mismatch**
- Ralph used wrong types
- Fix: Correct types based on definitions

**Pattern 4: Lint error due to style**
- Code works but style is off
- Fix: Adjust formatting

**Pattern 5: Build failure due to missing dependency**
- Imported something not installed
- Fix: Add dependency or use different approach

### Stuck in Loop

If Ralph repeatedly fails validation (3+ iterations on same task), the orchestrator's stuck detection will automatically:
1. Mark the task `[S]` in `IMPLEMENTATION_PLAN.md`
2. Add it to the `## Blocked` section
3. Move on to the next task

You can also intervene manually:

**Option 1: Regenerate plan**
```bash
rm IMPLEMENTATION_PLAN.md
./orchestrator.sh plan
```

**Option 2: Manual intervention**
```bash
# Stop loop
Ctrl+C

# Fix the issue manually
# Commit fix

# Restart loop
./orchestrator.sh
```

**Option 3: Update AGENTS.md**
Add guidance about the failure pattern so Ralph doesn't repeat it.

**Option 4: Force a stronger model for the stuck task**
Edit `IMPLEMENTATION_PLAN.md` to add `[opus]` before the task description, then restart.
```
- [ ] [opus] Fix the authentication bug
```
</handling_validation_failures>

<backpressure_as_learning>
## Backpressure as Learning

Validation failures teach Ralph:
- What "working" means for this project
- Edge cases to handle
- Patterns to follow
- Mistakes to avoid

Over time, validation failures should decrease as Ralph learns project patterns.

**Early loops:**
- Many validation failures
- Ralph learning patterns
- Prompts and AGENTS.md evolving

**Later loops:**
- Fewer validation failures
- Ralph aligned with patterns
- Stable prompts and learnings

**If failures increase:**
- Specs may have changed
- New complexity introduced
- Prompts may need update
- Consider plan regeneration
</backpressure_as_learning>

<no_tests_strategy>
## No Tests? Start Here

If project has no tests:

### Option 1: Ralph Creates Tests

Update building prompt:
```markdown
3. Implement
   - Write the functionality
   - Add unit tests for new functionality
   - Ensure tests pass before proceeding
```

Ralph will create tests as it implements features.

### Option 2: Add Minimal Test Framework

Before starting loop:
```bash
# JavaScript/TypeScript
npm install --save-dev vitest
# or jest, or your preferred framework

# Python
pip install pytest

# Go
# Built-in, just use: go test ./...

# Rust
# Built-in, just use: cargo test
```

Create one example test to establish pattern.

### Option 3: Use Type Checking Only

If tests are too much overhead initially:
```markdown
4. Validate
   - Run: tsc --noEmit  # or equivalent
   - Type errors must be fixed
```

Better than nothing. Add tests later when patterns stabilize.

### Option 4: Manual Smoke Tests

Define manual checks in AGENTS.md:
```markdown
## Validation

After each change:
- Run the application
- Test the changed feature manually
- Verify no errors in console
```

Not ideal (not automated) but establishes quality baseline.
</no_tests_strategy>

<tuning_backpressure>
## Tuning Backpressure

Start strict, loosen if too slow:

**Week 1:** Full validation (tests + types + lint + build)
- See where Ralph struggles
- Identify slow validation steps
- Note which checks catch real issues

**Week 2:** Remove low-value checks
- If linting catches nothing, remove it
- If build is slow and redundant with tests, remove it
- Keep only checks that catch real problems

**Week 3:** Add custom checks
- Based on observed failure patterns
- Aligned with actual quality needs
- Fast enough to not slow loop significantly

**Ongoing:** Evolve with project
- Add checks when new failure patterns emerge
- Remove checks when no longer catching issues
- Balance speed vs quality based on project phase

**Tuning infrastructure recovery:**
- `RALPH_MAX_STUCK=5` — increase if tasks are legitimately hard and need more attempts
- `./orchestrator.sh --model opus` — use when all tasks are complex and routing overhead isn't worth it
- `./orchestrator.sh --no-routing` — disable routing and rely on `RALPH_MODEL` env var
</tuning_backpressure>
