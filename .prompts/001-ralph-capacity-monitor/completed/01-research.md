# Research: Claude Capacity Data for Ralph Orchestrator

## Objective

Discover how to proactively retrieve Claude's 5-hour and weekly usage/capacity data from
within a Bash script, so the improved-ralph orchestrator can check limits before each
iteration rather than only reacting to exhaustion errors.

## Context

improved-ralph's `orchestrator.sh` (in `skills/setup-ralph/templates/`) currently handles
`USAGE_EXHAUSTED` errors reactively — only detecting them from Claude CLI output after a
call fails. The goal is to add **proactive capacity checking** at the top of each loop
iteration. The implementation language is Bash only (no Python/Node). Must work on both
macOS and Linux.

## Research Questions

### 1. Claude CLI usage commands

- Does the `claude` CLI expose a subcommand for querying current usage/quota?
  - Try: `claude --help`, `claude usage --help`, `claude account`, `claude status`,
    `claude quota`, `claude limits`
  - Document exact command, flags, and output format if found
- Does the CLI return structured output (JSON) or human-readable text?
- Does it report the 5-hour window usage? The weekly usage?

### 2. Local state files

- Does the Claude Code CLI write usage/capacity data to local files during operation?
- Check these locations (cross-platform):
  - `~/.claude/` — look for any files containing "usage", "limit", "quota", "window",
    "remaining", or timestamp fields
  - `~/.config/claude/`
  - `~/.local/share/claude/`
  - On macOS: `~/Library/Application Support/Claude/`
- If files exist: document their format, field names, and update frequency

### 3. Anthropic REST API

- Is there an Anthropic API endpoint that returns usage/quota data?
  - Check: `GET /v1/usage`, `GET /v1/account`, `GET /v1/limits`
  - Requires API key (`ANTHROPIC_API_KEY`) — can be called with `curl`
- Does the API return the 5-hour rolling window remaining?
- Does it return the weekly quota remaining and reset timestamp?
- Document the exact response schema (field names, types, units)

### 4. Response format analysis

Once a data source is found, document:
- How "percentage remaining" for the 5-hour limit is expressed (count, tokens, requests?)
- How "percentage remaining" for the weekly limit is expressed
- How the 5-hour reset timestamp is expressed (epoch, ISO 8601, relative seconds?)
- How the weekly reset timestamp is expressed
- Whether the weekly reset time is in UTC or local time

### 5. Open-source reference implementations

- Search GitHub for shell scripts or tools that monitor Claude Code / Anthropic API usage
- Search for `claude-code rate limit script`, `anthropic usage monitor bash`,
  `ralph wiggum capacity`, `claude quota check`
- Note any patterns or approaches used

### 6. Fallback approach

If no proactive data source exists (CLI or API), research:
- Can usage be inferred from the 5-hour window tracking already in
  `scripts/error-handler.sh` (the `WINDOW_START_FILE`)? That file records when the
  window started — but gives no info about how much of the quota was consumed.
- Is there a way to track cumulative token usage from Claude CLI output and estimate
  remaining capacity against a known quota ceiling?

## Deliverable Format

Produce a `<research>` XML document with:

```xml
<research>
  <summary>
    One-paragraph executive summary of findings: what data IS available, how to get it,
    and whether the feature as specified is feasible with a purely Bash implementation.
    If no proactive data source exists, clearly state that and recommend the best
    available approximation.
  </summary>

  <findings>
    <finding id="N">
      <source>Where this was found (command output, file path, URL)</source>
      <details>
        Exact output, field names, schema, and example values.
        Include exact shell commands to retrieve the data.
      </details>
    </finding>
    ...
  </findings>

  <recommendations>
    <recommendation id="N" title="short title">
      Concrete guidance for the Plan stage, given the research findings.
    </recommendation>
  </recommendations>

  <metadata>
    <confidence>High | Medium | Low</confidence>
    <open_questions>
      Any unresolved questions the Plan stage must address.
    </open_questions>
  </metadata>
</research>
```
