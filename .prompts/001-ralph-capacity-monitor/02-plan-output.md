<plan>
  <summary>
    Proactive capacity monitoring is added to the Ralph Orchestrator by introducing two new
    scripts — `capacity-claude.sh` (agent-specific fetcher) and `capacity-monitor.sh`
    (shared orchestration layer) — that are sourced by `orchestrator.sh` and invoked once
    per build-mode loop iteration before any task work begins. The design uses Anthropic's
    undocumented OAuth endpoint (`GET https://api.anthropic.com/api/oauth/usage`) with
    python3 for all JSON parsing (jq is not available on the target Windows/MSYS2 system),
    caches results for 60 seconds, and fails silently on any fetch error so Ralph is never
    blocked by a broken capacity check. The architecture defines a standard interface
    (`fetch_<agent>_capacity` function + four named variables) that makes adding Gemini or
    GPT-4 capacity checks a matter of dropping a new sourced script and registering one
    agent name.
  </summary>

  <files>

    <file action="new" path="skills/setup-ralph/templates/scripts/capacity-claude.sh">
      <description>
        Claude-specific capacity fetcher. Reads the OAuth access token from
        `~/.claude/.credentials.json` using python3, calls the Anthropic OAuth usage
        endpoint, caches the raw JSON response to `/tmp/ralph-usage-cache.json` with a
        60-second TTL, and populates four standard variables. Returns 0 on success,
        1 on any failure (missing credentials, curl error, HTTP 401, parse error). The
        script is self-contained and has no side effects beyond writing the cache file
        and setting the four variables.
      </description>
      <changes>
        - Declare `SCRIPT_DIR` using `$(cd "$(dirname "${BASH_SOURCE[0]}")" &amp;&amp; pwd)` pattern
          (matches classify-task.sh convention).

        - Define constants at the top of the file:
            CAPACITY_CACHE_FILE="/tmp/ralph-usage-cache.json"
            CAPACITY_CACHE_TTL=60          # seconds
            CAPACITY_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
            CAPACITY_BETA_HEADER="anthropic-beta: oauth-2025-04-20"
            CAPACITY_CREDS_FILE="$HOME/.claude/.credentials.json"

        - Define function `fetch_claude_capacity`:
          1. Preflight: check that python3 is available (`command -v python3`).
             If not, log "WARNING: python3 not available — capacity checking skipped"
             and return 1.

          2. Token extraction — try python3 (primary, always available):
               TOKEN=$(python3 -c "
                 import json, sys, os
                 path = os.path.expanduser('~/.claude/.credentials.json')
                 try:
                   d = json.load(open(path))
                   print(d['claudeAiOauth']['accessToken'])
                 except Exception as e:
                   sys.exit(1)
               " 2>/dev/null)
             If python3 extraction fails, return 1 (log "No Claude OAuth credentials
             found — capacity checking skipped").

          3. Cache TTL check: if `$CAPACITY_CACHE_FILE` exists AND its mtime is within
             60 seconds of `date +%s`, skip the curl call and read from the cache file
             directly. Use python3 for mtime check (cross-platform):
               MTIME=$(python3 -c "import os,time; \
                 f='$CAPACITY_CACHE_FILE'; \
                 print(int(time.time()-os.path.getmtime(f))) if os.path.exists(f) else print(9999)")
             If MTIME &lt; CAPACITY_CACHE_TTL, set CACHE_HIT=true; else CACHE_HIT=false.

          4. If CACHE_HIT=false: call curl with --max-time 5 --silent. Capture HTTP
             status code via `-w "%{http_code}"` and body separately. Command form:
               HTTP_BODY=$(curl -s --max-time 5 -w "\n%{http_code}" \
                 -H "Authorization: Bearer $TOKEN" \
                 -H "$CAPACITY_BETA_HEADER" \
                 -H "Content-Type: application/json" \
                 "$CAPACITY_USAGE_URL")
               HTTP_CODE=$(echo "$HTTP_BODY" | tail -1)
               RESPONSE=$(echo "$HTTP_BODY" | head -n -1)

          5. HTTP 401 handling: if HTTP_CODE == 401, log "[CAPACITY] claude — OAuth token
             expired, run 'claude login' to refresh" and return 1.

          6. HTTP non-200 / curl failure: if HTTP_CODE is not 200, or if curl exited
             non-zero (check $?), log "[CAPACITY] claude — fetch failed (HTTP $HTTP_CODE)"
             and return 1.

          7. On success: write RESPONSE to $CAPACITY_CACHE_FILE. Handle write failure
             gracefully (cache write is best-effort — non-fatal).

          8. Parse the cached/fresh JSON with python3:
               PARSE_RESULT=$(python3 -c "
                 import json, sys
                 from datetime import datetime, timezone
                 try:
                   d = json.load(open('$CAPACITY_CACHE_FILE'))
                   fh = d.get('five_hour') or {}
                   sd = d.get('seven_day') or {}
                   util_5h  = int(fh.get('utilization', 0))
                   reset_5h = fh.get('resets_at', '')
                   util_7d  = int(sd.get('utilization', 0))
                   reset_7d = sd.get('resets_at', '')
                   def to_epoch(ts):
                     if not ts:
                       return -1
                     try:
                       dt = datetime.fromisoformat(ts)
                       return int(dt.astimezone(timezone.utc).timestamp())
                     except Exception:
                       return -1
                   print(util_5h, to_epoch(reset_5h), util_7d, to_epoch(reset_7d))
                 except Exception as e:
                   print('ERROR', str(e), file=sys.stderr)
                   sys.exit(1)
               " 2>/tmp/ralph-capacity-parse-error.txt)
             On python3 parse error: log "[CAPACITY] claude — JSON parse failed" and
             return 1.

          9. Export the four standard variables by reading PARSE_RESULT fields:
               CAPACITY_5H_REMAINING_PCT=$((100 - util_5h))
               CAPACITY_5H_RESET_EPOCH=&lt;epoch from parse&gt;
               CAPACITY_WEEKLY_REMAINING_PCT=$((100 - util_7d))
               CAPACITY_WEEKLY_RESET_EPOCH=&lt;epoch from parse&gt;
             These variables are set in the caller's shell scope (not exported as env
             vars) so `capacity-monitor.sh` can read them directly.

          10. Return 0 on success.

        - Cache invalidation helper `invalidate_claude_capacity_cache`:
          Simply runs `rm -f "$CAPACITY_CACHE_FILE"`. Called from `orchestrator.sh`'s
          USAGE_EXHAUSTED branch (see orchestrator.sh changes) to force a fresh
          resets_at before sleeping.
      </changes>
    </file>

    <file action="new" path="skills/setup-ralph/templates/scripts/capacity-monitor.sh">
      <description>
        Shared orchestration layer for capacity monitoring. Sources each registered
        agent's capacity script, calls each agent's `fetch_&lt;agent&gt;_capacity` function,
        applies the 5-hour and weekly threshold rules defined in the spec, handles all
        sleeping (in 30-second increments with status-file checks), and appends one
        structured log line per agent per iteration. Exposes a single public function
        `check_all_agent_capacity` that `orchestrator.sh` calls once per loop.
      </description>
      <changes>
        - Declare `SCRIPT_DIR` using the standard BASH_SOURCE pattern.

        - Source agent scripts dynamically via a configurable list:
            CAPACITY_AGENTS="${RALPH_CAPACITY_AGENTS:-claude}"
            for _agent in $CAPACITY_AGENTS; do
              source "$SCRIPT_DIR/capacity-${_agent}.sh"
            done
          This is the extensibility seam: adding Gemini requires only placing
          `capacity-gemini.sh` in the scripts/ directory and setting
          `RALPH_CAPACITY_AGENTS="claude gemini"`.

        - Define constants (all overridable via environment variables):
            CAPACITY_5H_CRITICAL_PCT=5      # &lt; 5% remaining → wait for full reset
            CAPACITY_5H_WARN_PCT=20         # &lt; 20% remaining → sleep 1/3 of reset window
            CAPACITY_WEEKLY_WARN_PCT=20     # &lt; 20% remaining → conditional work-week pause
            CAPACITY_SLEEP_CHUNK=30         # max seconds per sleep increment

        - Define internal helper `_capacity_sleep_with_status_check &lt;total_seconds&gt; &lt;label&gt;`:
          Sleeps for `total_seconds` total, but wakes every `CAPACITY_SLEEP_CHUNK` seconds
          to re-read `$STATUS_FILE`:
            remaining=$total_seconds
            while [ "$remaining" -gt 0 ]; do
              chunk=$CAPACITY_SLEEP_CHUNK
              if [ "$remaining" -lt "$chunk" ]; then chunk=$remaining; fi
              sleep "$chunk"
              remaining=$((remaining - chunk))
              if [ -f "$STATUS_FILE" ] &amp;&amp; grep -qiE 'BREAK|INTERRUPT|STOP' "$STATUS_FILE" 2>/dev/null; then
                echo "[CAPACITY] $label — stop signal detected during sleep, exiting"
                echo "=== Orchestrator stopped via RALPH_STATUS.txt $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG_FILE"
                exit 0
              fi
            done
          LOG_FILE and STATUS_FILE are inherited from orchestrator.sh scope (already set
          before capacity-monitor.sh is sourced).

        - Define internal helper `_is_work_week`:
          Returns 0 (true) if the current local time is Monday 06:00 – Friday 18:00.
          Implementation using python3 (avoids `date -d` / `date -v` portability issues):
            python3 -c "
              from datetime import datetime
              now = datetime.now()
              dow = now.weekday()   # 0=Mon … 6=Sun
              h   = now.hour
              # Work week: Mon(0) 06:00 to Fri(4) 18:00
              if dow == 0 and h &lt; 6:   exit(1)   # Mon before 06:00
              if dow == 4 and h &gt;= 18: exit(1)   # Fri 18:00+
              if dow in (5, 6):         exit(1)   # Sat, Sun
              exit(0)
            " 2>/dev/null
          Returns its exit code directly.

        - Define internal helper `_epoch_is_work_week &lt;epoch&gt;`:
          Returns 0 (true) if the given Unix timestamp falls within the work week window,
          using the same python3 logic but with `datetime.fromtimestamp(epoch)`.

        - Define function `_check_5h_capacity &lt;agent&gt; &lt;pct_remaining&gt; &lt;reset_epoch&gt;`:
          Implements the 5-hour limit rules from the spec:
          1. If pct_remaining &lt; CAPACITY_5H_CRITICAL_PCT (default 5):
               now=$(date +%s)
               if [ "$reset_epoch" -gt "$now" ]; then
                 wait_secs=$((reset_epoch - now))
               else
                 wait_secs=0
               fi
               echo "[CAPACITY] $agent 5h=${pct_remaining_display}% weekly=... — waiting until 5h reset (${wait_secs}s)" >> "$LOG_FILE"
               echo same to stdout
               _capacity_sleep_with_status_check "$wait_secs" "$agent 5h-critical"
          2. Else if pct_remaining &lt; CAPACITY_5H_WARN_PCT (default 20):
               now=$(date +%s)
               time_until_reset=$((reset_epoch - now))
               if [ "$time_until_reset" -le 0 ]; then
                 # Window already reset, nothing to do
                 return 0
               fi
               sleep_secs=$((time_until_reset / 3))
               echo "[CAPACITY] $agent 5h=... — waiting 1/3 of reset window (${sleep_secs}s)" >> "$LOG_FILE"
               _capacity_sleep_with_status_check "$sleep_secs" "$agent 5h-warn"
          3. Else: no action (log OK line, return 0).

        - Define function `_check_weekly_capacity &lt;agent&gt; &lt;pct_remaining&gt; &lt;reset_epoch&gt;`:
          Implements the weekly limit rules from the spec:
          1. If pct_remaining &gt;= CAPACITY_WEEKLY_WARN_PCT: log OK line, return 0.
          2. If pct_remaining &lt; CAPACITY_WEEKLY_WARN_PCT:
             a. Determine if current time is work_week: `_is_work_week` → is_work=true/false
             b. Determine if reset_epoch falls in work_week: `_epoch_is_work_week $reset_epoch`
                → reset_in_work=true/false
             c. Decision matrix:
                  - is_work=false AND reset_in_work=false:
                      Log "work-week pause (currently weekend, reset in weekend: skipping pause)"
                      Return 0 (no pause needed — weekend work is fine)
                  - is_work=false AND reset_in_work=true:
                      Log "work-week pause (currently weekend, reset in work-week: skipping pause)"
                      Return 0 (reset happens during week, but we're on weekend — keep running)
                  - is_work=true AND reset_in_work=false:
                      Log "work-week pause (weekly reset in weekend: skipping pause)"
                      Return 0 (reset is coming on the weekend, safe to continue during work week)
                  - is_work=true AND reset_in_work=true:
                      Pause: wait in a loop until EITHER pct_weekly_remaining rises above 80%
                      OR current time is no longer in the work week AND reset is also in weekend.
                      Loop body:
                        _capacity_sleep_with_status_check 30 "$agent weekly-pause"
                        Re-call fetch_&lt;agent&gt;_capacity to get fresh data (cache will be
                        refreshed every 60 seconds; since loop sleeps 30s per chunk and
                        re-queries each outer iteration, cache stays fresh)
                        Re-evaluate _is_work_week and pct_weekly_remaining
                        Break if pct_weekly_remaining &gt;= 80 or we've left the work week
                      Log progress every loop iteration: "[CAPACITY] $agent weekly=${pct}% — work-week pause, checking again in 30s"

        - Define public function `check_all_agent_capacity`:
          For each agent in $CAPACITY_AGENTS:
            1. Call `fetch_${agent}_capacity`
               If it returns 1 (failure), skip this agent entirely (non-blocking).
            2. Read the four standard variables (set in calling scope by the fetch function):
                 pct_5h=$CAPACITY_5H_REMAINING_PCT
                 epoch_5h=$CAPACITY_5H_RESET_EPOCH
                 pct_weekly=$CAPACITY_WEEKLY_REMAINING_PCT
                 epoch_weekly=$CAPACITY_WEEKLY_RESET_EPOCH
            3. Log the check line:
                 "[CAPACITY] $agent 5h=${pct_5h}% weekly=${pct_weekly}% — ..."
               The status word at the end is determined by which threshold was triggered
               (OK / waiting 1/3 of reset window / waiting until 5h reset /
               work-week pause / work-week pause skipping).
            4. Call `_check_5h_capacity "$agent" "$pct_5h" "$epoch_5h"`
            5. Call `_check_weekly_capacity "$agent" "$pct_weekly" "$epoch_weekly"`
          Return 0 always (the `|| true` in orchestrator.sh makes the return value
          advisory-only, but this function never returns non-zero in practice).

        - Log format details:
          All log lines are written with `echo "..." >> "$LOG_FILE"` AND mirrored to
          stdout so the terminal shows the check result. The four example formats from
          the spec are the canonical output format:
            [CAPACITY] claude 5h=73% weekly=91% — OK
            [CAPACITY] claude 5h=14% weekly=91% — waiting 1/3 of reset window (412s)
            [CAPACITY] claude 5h=3% weekly=91% — waiting until 5h reset (1847s)
            [CAPACITY] claude 5h=73% weekly=17% — work-week pause (weekly reset in weekend: skipping pause)
      </changes>
    </file>

    <file action="modify" path="skills/setup-ralph/templates/orchestrator.sh">
      <description>
        Two minimal additions to orchestrator.sh: source `capacity-monitor.sh` alongside
        the existing helper scripts at startup, and insert one function call at the exact
        position in the main loop specified by the spec (after iteration-limit check,
        before plan-file existence check). No other changes to orchestrator.sh.
      </description>
      <changes>
        - Add one source line in the "Source helpers" block at lines 31-33, after the
          existing three source lines:
            source "$ORCHESTRATOR_DIR/scripts/capacity-monitor.sh"
          Placement: immediately after `source "$ORCHESTRATOR_DIR/scripts/error-handler.sh"`
          (line 33). The capacity monitor depends on LOG_FILE and STATUS_FILE being
          defined, which they are by line 80/79 — but sourcing happens before the main
          loop, so by the time `check_all_agent_capacity` is called, those variables are
          already set.

        - Add a capacity check call in the main `while true` loop (lines 296-456),
          after the iteration-limit check block (lines 308-312) and before the plan-file
          existence check (lines 314-319). Insert at approximately line 313:
            # Check capacity before proceeding (build mode only — already inside build-mode
            # section; plan/decompose modes exit before reaching this loop)
            check_all_agent_capacity || true

        - In the USAGE_EXHAUSTED error handler branch (currently around line 419-423),
          add a cache invalidation call before `sleep_until_window_resets`:
            invalidate_claude_capacity_cache 2>/dev/null || true
          This ensures the next capacity check after waking up gets a fresh resets_at
          from the server rather than a stale 60-second cached value.

        - Update the `sleep_until_window_resets` usage in the USAGE_EXHAUSTED branch to
          prefer the server-authoritative reset time from the capacity cache when available.
          The preferred approach: after invalidating the cache, immediately re-call
          `fetch_claude_capacity` and if CAPACITY_5H_RESET_EPOCH &gt; 0, use that epoch
          directly for the sleep duration instead of the WINDOW_START_FILE estimate.
          Keep the existing WINDOW_START_FILE fallback if the fetch fails.
          Implementation in the USAGE_EXHAUSTED branch (replaces lines 420-423):
            invalidate_claude_capacity_cache 2>/dev/null || true
            if fetch_claude_capacity 2>/dev/null &amp;&amp; [ "${CAPACITY_5H_RESET_EPOCH:-0}" -gt 0 ]; then
              _now=$(date +%s)
              _sleep_secs=$(( CAPACITY_5H_RESET_EPOCH - _now ))
              if [ "$_sleep_secs" -gt 0 ]; then
                echo "Usage window exhausted. Sleeping ${_sleep_secs}s (server reset time)."
                _capacity_sleep_with_status_check "$_sleep_secs" "usage-exhausted"
              fi
            else
              sleep_until_window_resets
            fi
          Note: `_capacity_sleep_with_status_check` is available because
          capacity-monitor.sh is sourced at startup.

        - No other changes. ralph.sh is not touched. Error handler function signatures
          are not changed. No new required env vars (RALPH_CAPACITY_AGENTS,
          CAPACITY_5H_CRITICAL_PCT, etc. are all optional with safe defaults).
      </changes>
    </file>

    <file action="modify" path="skills/setup-ralph/templates/scripts/error-handler.sh">
      <description>
        Minor update to `sleep_until_window_resets` to prefer the server-authoritative
        reset time from the capacity cache when available, falling back to the existing
        WINDOW_START_FILE estimate. No function signature changes. No new public API.
      </description>
      <changes>
        - The primary change to this file lives in orchestrator.sh's USAGE_EXHAUSTED
          branch (see above). The error-handler.sh function `sleep_until_window_resets`
          itself does NOT need to change — it remains as a fallback that orchestrator.sh
          calls only when the capacity fetch fails.

        - No changes to: `mark_window_start`, `handle_rate_limit`, `handle_overloaded`,
          `reset_error_counters`, `cleanup_error_handler`, `estimate_prompt_tokens`,
          `classify_error`. All function signatures remain identical.

        - Only documentation comment update: add a note to `sleep_until_window_resets`
          that it is now a fallback used only when the oauth/usage cache is unavailable,
          and that orchestrator.sh now prefers the server-authoritative epoch from
          CAPACITY_5H_RESET_EPOCH when capacity-monitor.sh is loaded.
      </changes>
    </file>

  </files>

  <implementation_notes>
    1. PYTHON3 ONLY FOR JSON — no jq dependency.
       On the target Windows/MSYS2 system, jq is confirmed absent. All JSON parsing in
       both capacity-claude.sh and capacity-monitor.sh must use python3. The python3
       one-liners in the plan use the standard library only (json, datetime, os, sys).
       Never use `date -d` (Linux only) or `date -v` (macOS only) for ISO 8601 parsing.
       Use `datetime.fromisoformat()` with `.astimezone(timezone.utc).timestamp()`.

    2. VARIABLE SCOPING — standard variables are shell variables, not exported.
       `fetch_claude_capacity` sets CAPACITY_5H_REMAINING_PCT etc. as ordinary shell
       variables in the current shell. Since capacity-monitor.sh and capacity-claude.sh
       are both sourced (not subprocess-called), all variables share the same shell scope
       as orchestrator.sh. Do not use `export` unless the variable also needs to be
       visible to subprocesses (none of the four standard variables do).

    3. CACHE FILE LOCATION — /tmp is universally writable.
       `/tmp/ralph-usage-cache.json` is appropriate for Linux and macOS. On Windows
       running MSYS2/Git Bash, /tmp maps to the MSYS2 /tmp directory which is writable.
       If `/tmp` is not writable (unusual edge case), the write fails silently and the
       next call will attempt a fresh fetch. The implementation must never abort on a
       cache write failure.

    4. CAPACITY_AGENTS LOOP — must handle spaces and newlines in the IFS correctly.
       The agent loop `for _agent in $CAPACITY_AGENTS` works when CAPACITY_AGENTS is a
       space-separated list (e.g. "claude gemini"). Do not quote the variable in the for
       loop (intentional word-splitting). Source failures for agent scripts must be
       caught: wrap each source in a conditional:
         if [ -f "$SCRIPT_DIR/capacity-${_agent}.sh" ]; then
           source "$SCRIPT_DIR/capacity-${_agent}.sh"
         else
           echo "WARNING: No capacity script for agent '${_agent}' — skipping"
         fi

    5. STATUS_FILE AND LOG_FILE INHERITANCE.
       capacity-monitor.sh uses `$STATUS_FILE` and `$LOG_FILE` which are defined in
       orchestrator.sh before any sourcing occurs (lines 79-80). Since the script is
       sourced (not exec'd), these variables are in scope. The implementation must not
       redefine them in capacity-monitor.sh — only use them.

    6. WORK WEEK BOUNDARY — local time, not UTC.
       The spec defines work week as Monday 06:00 to Friday 18:00 **local time**.
       `datetime.now()` (without tzinfo) returns local time, which is correct.
       `datetime.fromtimestamp(epoch)` also returns local time — correct for
       `_epoch_is_work_week`. Do NOT use `datetime.utcnow()` or `timezone.utc` for
       the work-week check.

    7. WEEKLY PAUSE RE-QUERY FREQUENCY.
       During a weekly pause, the inner loop sleeps 30 seconds per chunk (via
       `_capacity_sleep_with_status_check`). After each wake, `fetch_&lt;agent&gt;_capacity`
       is called again. Since the cache TTL is 60 seconds, every other wake cycle will
       actually hit the network. This is acceptable — roughly one API call per minute
       during a pause, which is not abusive.

    8. ORCHESTRATOR.SH SOURCING ORDER.
       `capacity-monitor.sh` must be sourced AFTER `error-handler.sh` (for access to
       the `sleep_until_window_resets` fallback) but the internal `_capacity_sleep_with_status_check`
       does not depend on error-handler.sh. Sourcing after error-handler.sh (line 33 in
       orchestrator.sh) is the correct position.

    9. PLAN MODE / DECOMPOSE MODE — capacity check is NOT inserted.
       The spec says "build mode only". The main `while true` loop is only reached in
       build mode (plan and decompose modes `exec` or `exit` before reaching the loop).
       No conditional guard (`if [ "$MODE" = "build" ]`) is needed around the
       `check_all_agent_capacity` call because the function is only ever reached during
       build mode. However, adding a comment clarifying this intent is good practice.

    10. SEVEN_DAY_OPUS — future extension, not in initial implementation.
        The research identifies `seven_day_opus` as a separate field that could trigger
        model downgrade instead of full pause. The initial implementation reads only
        `five_hour` and `seven_day`. When seven_day_opus support is added, it would
        be implemented as a new variable pair (CAPACITY_OPUS_REMAINING_PCT /
        CAPACITY_OPUS_RESET_EPOCH) in capacity-claude.sh, and a new threshold check
        in capacity-monitor.sh that calls `downgrade_opus_to_sonnet` (TBD function in
        model-config.sh) rather than sleeping.
  </implementation_notes>

  <risks>
    1. FETCH FAILURE — oauth/usage endpoint is undocumented and may change.
       Mitigation: The entire capacity check is wrapped so that any non-zero return from
       `fetch_claude_capacity` causes `check_all_agent_capacity` to skip that agent and
       return 0. Ralph never blocks due to a broken capacity endpoint. Log lines clearly
       indicate when a check was skipped vs. when it returned a real reading.

    2. MISSING CREDENTIALS — user running Ralph without a Claude subscription (API key only).
       Mitigation: If `~/.claude/.credentials.json` does not exist, `fetch_claude_capacity`
       returns 1 immediately with a single log line. This is a permanent skip (not retried
       each iteration) for users without subscriptions. Consider setting
       `RALPH_CAPACITY_AGENTS=""` in the orchestrator docs for pure API-key users.

    3. STALE CACHE AFTER USAGE_EXHAUSTED.
       If Ralph hits USAGE_EXHAUSTED and the cache still shows low utilization (race
       condition between the reactive error and the proactive check), the sleep duration
       from the cache's resets_at could be wrong. Mitigation: `invalidate_claude_capacity_cache`
       is called immediately on USAGE_EXHAUSTED before re-fetching, ensuring the next
       fetch gets the post-exhaustion resets_at from the server.

    4. STATUS_FILE MISSING DURING SLEEP.
       If RALPH_STATUS.txt is deleted while `_capacity_sleep_with_status_check` is
       running, the `[ -f "$STATUS_FILE" ]` check will simply not fire (the file is
       absent, not containing a stop signal). Ralph will wake normally when the sleep
       completes. This is the correct behavior — deletion means the user removed the
       file, not that they sent a stop signal.

    5. STATUS_FILE CHECK DURING SLEEP — exit vs. return.
       `_capacity_sleep_with_status_check` calls `exit 0` (not `return`) when a stop
       signal is detected. This is correct because the function is called from within
       the main loop of orchestrator.sh, and returning would require every call site
       to check the return code. Using `exit 0` mirrors the behavior of the existing
       stop-signal check at the top of the main loop. The EXIT trap in orchestrator.sh
       (calling `orchestrator_cleanup`) will still fire on `exit 0`.

    6. PYTHON3 SUBPROCESS OVERHEAD.
       Each call to `fetch_claude_capacity` spawns two python3 subprocesses (one for
       token extraction, one for parsing). On a cold cache, it also spawns a curl process.
       The total overhead is &lt; 200ms per iteration, which is negligible given that each
       loop iteration invokes a full Claude session. On a warm cache hit (60s TTL), the
       mtime check still spawns one python3 process to check the file age.

    7. RESET_EPOCH = -1 WHEN WINDOW HAS NOT STARTED.
       If `five_hour.resets_at` is null (window not yet started — no usage), the parsed
       CAPACITY_5H_RESET_EPOCH will be -1. The `_check_5h_capacity` function must guard
       against this: if reset_epoch == -1 and pct_remaining &lt; threshold, log a warning
       and skip sleeping (since we do not know when the window resets). Do not attempt
       to sleep a negative or zero duration.

    8. CLOCK SKEW BETWEEN LOCAL MACHINE AND ANTHROPIC SERVERS.
       `resets_at` is a UTC server timestamp; `date +%s` is the local clock. If the local
       clock is significantly off (minutes), sleep durations will be wrong. Mitigation:
       cap minimum sleep to 0 (never sleep negative durations); add a 30-second buffer
       to the computed sleep duration for the critical path (5h &lt; 5% case) to account
       for minor clock drift:
         wait_secs=$((reset_epoch - now + 30))
  </risks>

  <verification_criteria>
    1. MANUAL TEST — 5-hour &lt; 5% path.
       a. Temporarily modify capacity-claude.sh to hardcode CAPACITY_5H_REMAINING_PCT=3
          and CAPACITY_5H_RESET_EPOCH=$(( $(date +%s) + 120 )) (reset in 2 minutes).
       b. Run `./orchestrator.sh 1` (limit 1 iteration) with a valid IMPLEMENTATION_PLAN.md.
       c. Expected behavior: orchestrator logs "[CAPACITY] claude 5h=3% weekly=...% —
          waiting until 5h reset (NNs)", then sleeps approximately 120 seconds, then
          proceeds to execute one iteration. If RALPH_STATUS.txt is written with "STOP"
          during the sleep, orchestrator should exit cleanly within 30 seconds.
       d. Verify ralph.log contains the [CAPACITY] line.
       e. Remove the hardcoded values after testing.

    2. MANUAL TEST — work-week weekly pause path.
       a. Temporarily hardcode CAPACITY_WEEKLY_REMAINING_PCT=15 and set
          CAPACITY_WEEKLY_RESET_EPOCH to a timestamp that falls on a Tuesday
          (within the work week).
       b. Run the orchestrator on a weekday between 06:00 and 18:00 local time.
       c. Expected: orchestrator enters the weekly pause loop, logs "[CAPACITY] claude
          weekly=15% — work-week pause", and waits. Raise the mocked value to 85% after
          one sleep cycle (by modifying the hardcoded return value while the script sleeps)
          — the orchestrator should exit the pause loop and proceed.
       d. Run the same test on a Saturday (or mock `_is_work_week` to return 1):
          expected — pause is skipped, "[CAPACITY] ... work-week pause (currently weekend
          ...)" is logged, and the orchestrator proceeds immediately.

    3. MANUAL TEST — status-file exit during sleep.
       a. Start orchestrator with the 5h &lt; 5% mock (2-minute sleep target from test 1).
       b. While it is sleeping, write "STOP" to RALPH_STATUS.txt:
            echo "STOP" > RALPH_STATUS.txt
       c. Expected: within 30 seconds (one sleep chunk), orchestrator logs "[CAPACITY]
          ... — stop signal detected during sleep, exiting" and exits with code 0.
       d. Verify the EXIT trap ran (stuck tracker and temp file cleaned up, log shows
          "Orchestrator stopped via RALPH_STATUS.txt").

    4. MANUAL TEST — adding a second agent in &lt; 10 lines.
       a. Create `scripts/capacity-gemini.sh` with only:
            fetch_gemini_capacity() {
              CAPACITY_5H_REMAINING_PCT=50
              CAPACITY_5H_RESET_EPOCH=-1
              CAPACITY_WEEKLY_REMAINING_PCT=50
              CAPACITY_WEEKLY_RESET_EPOCH=-1
              return 0
            }
       b. Set `export RALPH_CAPACITY_AGENTS="claude gemini"` in the shell.
       c. Run the orchestrator. Expected: ralph.log shows two [CAPACITY] lines per
          iteration — one for `claude` and one for `gemini` — with no code changes to
          capacity-monitor.sh or orchestrator.sh.
       d. Line count of capacity-gemini.sh stub: 7 lines (function open, 4 variables,
          return, function close). This confirms the &lt; 10 lines requirement.

    5. AUTOMATED VERIFICATION — cache TTL behavior.
       a. Delete `/tmp/ralph-usage-cache.json` if it exists.
       b. Call `fetch_claude_capacity` (source capacity-claude.sh first, then call the
          function directly from bash).
       c. Check that `/tmp/ralph-usage-cache.json` now exists and contains valid JSON.
       d. Immediately call `fetch_claude_capacity` again. Verify (via strace or by
          mocking curl to fail) that curl is NOT called the second time (cache hit).
       e. Set the mtime of the cache file to 61 seconds in the past:
            touch -t $(date -d '70 seconds ago' +%Y%m%d%H%M.%S) /tmp/ralph-usage-cache.json
            (Linux) or use python3 to set mtime directly.
       f. Call `fetch_claude_capacity` again. Verify curl IS called (cache miss).

    6. LOG FORMAT VERIFICATION.
       Run the orchestrator for 3 iterations with real or mocked capacity data covering
       all four log-line variants from the spec. Grep ralph.log for "^\\[CAPACITY\\]"
       and confirm each line matches the expected format:
         [CAPACITY] &lt;agent&gt; 5h=&lt;N&gt;% weekly=&lt;N&gt;% — &lt;status message&gt;
       Confirm no [CAPACITY] lines appear in plan mode or decompose mode output.
  </verification_criteria>

</plan>
