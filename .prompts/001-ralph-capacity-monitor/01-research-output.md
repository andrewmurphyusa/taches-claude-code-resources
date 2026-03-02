<research>
  <summary>
    Proactive capacity checking IS feasible in pure Bash for Claude Pro/Max subscription
    users. Anthropic exposes an undocumented OAuth endpoint —
    GET https://api.anthropic.com/api/oauth/usage — that returns the 5-hour utilization
    percentage and reset timestamp, plus the 7-day (weekly) utilization percentage and
    reset timestamp. The OAuth access token is stored in ~/.claude/.credentials.json
    (on Linux and Windows/MSYS2 bash) as .claudeAiOauth.accessToken, making it
    accessible to a shell script via jq or python3. The Claude CLI has no usage/quota
    subcommand; the local stats-cache.json file stores historical counts only (no
    remaining quota). For pure API-key users (no subscription), no analogous endpoint
    exists — those users have only RPM/ITPM/OTPM rate limits returned as HTTP response
    headers on each API call. Since improved-ralph targets Claude Pro/Max subscription
    users (confirmed: the local .credentials.json contains subscriptionType and
    rateLimitTier fields), the OAuth endpoint is the correct data source.
  </summary>

  <findings>
    <finding id="1">
      <source>claude --help (CLI introspection, local execution)</source>
      <details>
        The claude CLI exposes exactly five subcommands as of 2026-03-02:
          doctor, install, mcp, plugin, setup-token

        There is NO usage, account, status, quota, or limits subcommand.
        Running `claude usage`, `claude account`, `claude status`, `claude quota`,
        or `claude limits` all produce the main help text and exit — none return
        usage data.

        The CLI offers --max-budget-usd (spending cap per --print invocation) and
        --output-format=json (structured output for a session), but neither reports
        current subscription consumption.
      </details>
    </finding>

    <finding id="2">
      <source>~/.claude/ filesystem enumeration (local filesystem)</source>
      <details>
        Files present in ~/.claude/ (Windows/MSYS2, confirmed on this system):
          .credentials.json   — OAuth tokens (see Finding 3)
          stats-cache.json    — Historical usage data (see Finding 4)
          settings.json       — User configuration
          mcp-needs-auth-cache.json
          cache/changelog.md
          plans/, projects/, skills/, todos/, telemetry/, debug/
          ide/, shell-snapshots/, backups/, file-history/

        No files named: usage, quota, limit, window, remaining, capacity.
        No files in ~/.config/claude/ or ~/.local/share/claude/ (not present on this system).
        macOS equivalent: ~/Library/Application Support/Claude/ — not applicable here.
      </details>
    </finding>

    <finding id="3">
      <source>~/.claude/.credentials.json (local filesystem, confirmed present)</source>
      <details>
        The file contains a JSON object with this structure (field names confirmed,
        values redacted):

          {
            "claudeAiOauth": {
              "accessToken":    string (length 108) — Bearer token for API calls
              "refreshToken":   string (length 108) — OAuth refresh token
              "expiresAt":      integer              — Unix epoch expiry
              "scopes":         array[4]             — OAuth scopes
              "subscriptionType": string (length 3)  — e.g. "max", "pro"
              "rateLimitTier":  string (length 17)   — e.g. "claude_max_5x"
            },
            "organizationUuid": string (length 36)
          }

        Cross-platform access in bash:
          # Linux / WSL / Windows MSYS2 / Git Bash:
          TOKEN=$(jq -r '.claudeAiOauth.accessToken' ~/.claude/.credentials.json)

          # Fallback without jq (using python3, available everywhere):
          TOKEN=$(python3 -c "import json,sys; \
            d=json.load(open('$HOME/.claude/.credentials.json')); \
            print(d['claudeAiOauth']['accessToken'])")

          # macOS (Keychain):
          CREDS=$(security find-generic-password -s "Claude Code-credentials" -w)
          TOKEN=$(echo "$CREDS" | jq -r '.claudeAiOauth.accessToken')

        IMPORTANT: On this Windows system, jq is NOT installed in the MSYS2/Git Bash
        PATH. python3 (3.13.12) IS available. The Plan stage must handle jq absence
        gracefully, falling back to python3 for JSON parsing.

        Token expiry: the expiresAt field suggests tokens expire. Ralph should detect
        401 responses (invalid/expired token) and emit a clear error rather than
        silently failing.
      </details>
    </finding>

    <finding id="4">
      <source>~/.claude/stats-cache.json (local filesystem, confirmed present)</source>
      <details>
        Contains historical usage statistics, NOT quota/remaining data.

        Schema (version 2, as of 2026-03-01):
          dailyActivity[]:     { date, messageCount, sessionCount, toolCallCount }
          dailyModelTokens[]:  { date, tokensByModel: { model_id: tokens } }
          modelUsage{model_id}: {
            inputTokens, outputTokens,
            cacheReadInputTokens, cacheCreationInputTokens,
            webSearchRequests, costUSD (= 0 for subscription users),
            contextWindow, maxOutputTokens
          }
          totalSessions, totalMessages, longestSession, firstSessionDate,
          hourCounts{}, totalSpeculationTimeSavedMs

        Key observation: costUSD is 0 for all models (subscription, not API-key billing).
        The file provides NO quota ceiling, NO remaining capacity, NO window reset time.
        It cannot be used to infer remaining capacity without knowing the plan's ceiling
        (and even then, it only covers output since the window started, not the full
        rolling window).

        Update frequency: appears to be updated at the end of each session.
      </details>
    </finding>

    <finding id="5">
      <source>https://api.anthropic.com/api/oauth/usage
               (confirmed via codelynx.dev, usagebar.com, Firnschnee/Tray-Usage-Monitor)</source>
      <details>
        ENDPOINT: GET https://api.anthropic.com/api/oauth/usage
        STATUS: Undocumented (internal OAuth API, not part of /v1/ public API)
        WORKS FOR: Claude Pro/Max subscription users only (OAuth token required)

        REQUIRED HEADERS:
          Authorization: Bearer <accessToken>
          anthropic-beta: oauth-2025-04-20
          Content-Type: application/json

        EXAMPLE curl COMMAND:
          TOKEN=$(python3 -c "import json; \
            d=json.load(open('$HOME/.claude/.credentials.json')); \
            print(d['claudeAiOauth']['accessToken'])")

          USAGE=$(curl -s --max-time 5 \
            "https://api.anthropic.com/api/oauth/usage" \
            -H "Authorization: Bearer $TOKEN" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Content-Type: application/json")

        RESPONSE SCHEMA:
          {
            "five_hour": {
              "utilization": 6.0,                              // 0.0–100.0 percentage consumed
              "resets_at":  "2025-11-04T04:59:59.943648+00:00" // UTC ISO 8601 with microseconds
            },
            "seven_day": {
              "utilization": 35.0,
              "resets_at":  "2025-11-06T03:59:59.943679+00:00"
            },
            "seven_day_oauth_apps": null,
            "seven_day_opus": {
              "utilization": 0.0,
              "resets_at": null                                // null when opus not used
            },
            "iguana_necktie": null                             // unknown internal field
          }

        FIELD SEMANTICS:
          utilization:  percentage of the window's allocation already consumed (0.0–100.0)
          resets_at:    UTC ISO 8601 timestamp when the window fully resets
                        (null when the window has not started / no Opus usage)

        PARSING (python3, no jq required):
          FIVE_PCT=$(echo "$USAGE" | python3 -c "
            import json,sys
            d=json.load(sys.stdin)
            fh=d.get('five_hour') or {}
            print(int(fh.get('utilization', 0)))")

          FIVE_RESETS=$(echo "$USAGE" | python3 -c "
            import json,sys
            d=json.load(sys.stdin)
            fh=d.get('five_hour') or {}
            print(fh.get('resets_at',''))")

          SEVEN_PCT=$(echo "$USAGE" | python3 -c "
            import json,sys
            d=json.load(sys.stdin)
            sd=d.get('seven_day') or {}
            print(int(sd.get('utilization', 0)))")

        RESETS_AT TO EPOCH (for sleep calculation):
          # Linux:
          EPOCH=$(date -ud "$FIVE_RESETS" +%s 2>/dev/null)
          # macOS:
          CLEAN=$(echo "$FIVE_RESETS" | sed 's/\..*//' | sed 's/+.*//')
          EPOCH=$(date -juf "%Y-%m-%dT%H:%M:%S" "$CLEAN" +%s 2>/dev/null)
          # python3 (cross-platform):
          EPOCH=$(python3 -c "
            from datetime import datetime, timezone
            ts='$FIVE_RESETS'
            if ts:
              dt=datetime.fromisoformat(ts)
              print(int(dt.astimezone(timezone.utc).timestamp()))")

        CACHING RECOMMENDATION: Cache the response to /tmp/ralph-usage-cache.json with
        a 60-second TTL to avoid hammering the endpoint at every loop iteration.
      </details>
    </finding>

    <finding id="6">
      <source>platform.claude.com/docs/en/api/rate-limits (official Anthropic docs)</source>
      <details>
        For API-KEY users (not subscription), rate limits are returned as HTTP response
        headers on every API call — there is NO dedicated query endpoint:

          anthropic-ratelimit-requests-limit          — max requests per window
          anthropic-ratelimit-requests-remaining      — remaining requests
          anthropic-ratelimit-requests-reset          — RFC 3339 reset time
          anthropic-ratelimit-tokens-limit            — max tokens per window
          anthropic-ratelimit-tokens-remaining        — remaining (nearest 1000)
          anthropic-ratelimit-tokens-reset            — RFC 3339 reset time
          anthropic-ratelimit-input-tokens-*          — input-specific variants
          anthropic-ratelimit-output-tokens-*         — output-specific variants
          retry-after                                 — seconds to wait (on 429)

        These are per-minute RPM/ITPM/OTPM limits — NOT 5-hour or weekly subscription
        limits. They apply only to API-key billing, not Claude Pro/Max plans.

        The Claude CLI (when used with a subscription) uses OAuth internally, not an
        API key, so these headers are not exposed to a wrapping bash script.
      </details>
    </finding>

    <finding id="7">
      <source>GitHub: Firnschnee/Tray-Usage-Monitor (Windows C# tool)
               GitHub gist: jtbr/4f99671d1cee06b44106456958caba8b (bash statusline)</source>
      <details>
        Multiple open-source implementations confirm the oauth/usage endpoint pattern:

        Windows Tray Monitor (C#, .NET 8):
          - Reads from Windows Credential Manager ("Claude Code-credentials" entry)
          - Falls back to %USERPROFILE%\.claude\.credentials.json
          - Calls GET https://api.anthropic.com/api/oauth/usage with Bearer token
          - Displays five_hour and seven_day utilization

        Bash statusline (gist):
          - Linux: reads ~/.claude/.credentials.json directly
          - macOS: uses `security find-generic-password`
          - Caches response to /tmp/claude-statusline-usage.json (60s TTL)
          - Extracts utilization via jq: jq -r '.five_hour.utilization // empty'
          - Converts resets_at to epoch for sleep arithmetic

        Key bash implementation pattern (jq version):
          usage_5h=$(jq -r '.five_hour.utilization // empty' /tmp/cache.json | cut -d. -f1)
          resets_5h=$(jq -r '.five_hour.resets_at // empty' /tmp/cache.json)
      </details>
    </finding>

    <finding id="8">
      <source>skills/setup-ralph/templates/scripts/error-handler.sh (local codebase)</source>
      <details>
        Current improved-ralph error-handler.sh uses a WINDOW_START_FILE to track
        when the 5-hour window began (written as epoch seconds at first success).
        It computes remaining sleep time as: (window_start + 18300) - now.

        This approach has a critical flaw: it records when Ralph STARTED the window,
        not when Anthropic's server considers the window to have started. The server
        tracks consumption from the first message of the billing period, which may
        predate Ralph's session. The oauth/usage endpoint's resets_at is authoritative.

        The WINDOW_START_FILE approach can be REPLACED by:
          1. At loop start, query oauth/usage to get five_hour.resets_at
          2. If five_hour.utilization >= threshold (e.g. 90%), sleep until resets_at
          3. On USAGE_EXHAUSTED error (reactive), use resets_at for precise sleep
             instead of estimating from WINDOW_START_FILE

        This gives accurate server-side reset times rather than client-estimated ones.
      </details>
    </finding>
  </findings>

  <recommendations>
    <recommendation id="1" title="Use oauth/usage as primary capacity source">
      The Plan stage should design check_capacity() as a bash function that:
        1. Reads the OAuth token from ~/.claude/.credentials.json using python3
           (jq not available on this Windows system; python3 3.13 IS available)
        2. Calls GET https://api.anthropic.com/api/oauth/usage with the Bearer token
           and anthropic-beta: oauth-2025-04-20 header
        3. Caches the JSON response to /tmp/ralph-usage-cache.json with a 60-second TTL
           (avoid calling the endpoint on every iteration — check mtime against 60s)
        4. Returns structured output: five_hour_pct, five_hour_resets_at,
           seven_day_pct, seven_day_resets_at
        5. Handles failure gracefully (curl timeout, 401, parse error) by returning
           "unknown" state — which should NOT block Ralph from running
    </recommendation>

    <recommendation id="2" title="Define configurable thresholds for preemptive pause">
      Capacity check should pause Ralph BEFORE hitting 100% exhaustion. Suggested
      default thresholds (configurable via env vars in orchestrator.sh):
        RALPH_CAPACITY_5H_THRESHOLD=90    # pause when five_hour >= 90%
        RALPH_CAPACITY_7D_THRESHOLD=95    # pause when seven_day >= 95%

      When threshold is crossed, the function should sleep until resets_at (converting
      ISO 8601 to epoch via python3 datetime.fromisoformat, cross-platform).
      Log the pause with both utilization percentage and human-readable reset time.
    </recommendation>

    <recommendation id="3" title="Replace WINDOW_START_FILE with server-authoritative resets_at">
      The current error-handler.sh sleep_until_window_resets() uses a client-estimated
      window start time. Replace this with:
        1. Cache the resets_at from the most recent oauth/usage call
        2. On USAGE_EXHAUSTED error, use the cached resets_at as sleep target
        3. Fall back to current behaviour (5-hour sleep) only if the cache is missing

      This gives accurate server-side timing and eliminates the systematic error of
      estimating the window start from Ralph's session start.
    </recommendation>

    <recommendation id="4" title="Handle missing jq with python3 fallback">
      The Plan/Implement stages must NOT assume jq is available. Use python3 for all
      JSON parsing in the new check_capacity() function. python3 is confirmed present
      on this system (3.13.12) and is available on macOS and all major Linux distros.
      Add a preflight check: if neither jq nor python3 is available, emit a clear
      warning and skip capacity checking (non-blocking degradation).
    </recommendation>

    <recommendation id="5" title="Handle token expiry and non-subscription gracefully">
      The credentials accessToken has an expiresAt field. Add handling for:
        - HTTP 401 response: log "OAuth token expired — run 'claude login' to refresh"
          and skip capacity check for this iteration (do not abort Ralph)
        - Missing ~/.claude/.credentials.json: log "No credentials found — capacity
          checking disabled" (user may be using API key, not subscription)
        - Empty/null utilization: treat as 0% (window not yet started)
      Capacity checking must be entirely non-blocking — if it fails for any reason,
      Ralph continues running. Only a confirmed high-utilization reading should pause.
    </recommendation>

    <recommendation id="6" title="Add seven_day_opus as separate check for Opus users">
      The oauth/usage response includes seven_day_opus with its own utilization and
      resets_at. Since improved-ralph uses Opus for complex tasks, the Plan should
      include a separate RALPH_CAPACITY_7D_OPUS_THRESHOLD (default: 90%) that triggers
      model downgrade (from Opus to Sonnet) rather than full pause, preserving Ralph's
      ability to continue working on simpler tasks within the weekly Opus sub-limit.
    </recommendation>
  </recommendations>

  <metadata>
    <confidence>High</confidence>
    <open_questions>
      1. TOKEN REFRESH: The credentials.json contains a refreshToken and expiresAt.
         How long do OAuth tokens last? Should the Plan include token refresh logic
         (calling the OAuth refresh endpoint), or just prompt the user to re-run
         `claude login`? The codelynx.dev implementation doesn't show refresh logic,
         suggesting tokens are long-lived enough that manual re-login is acceptable.

      2. ENDPOINT STABILITY: The oauth/usage endpoint is undocumented and uses a
         beta header (oauth-2025-04-20). It could change or disappear. The Plan
         should include a version-check or graceful degradation if the endpoint
         returns 404 or an unexpected schema.

      3. SUBSCRIPTION TYPE MAPPING: The credentials.json contains subscriptionType
         (3-char string) and rateLimitTier (17-char string). These may map to known
         ceiling values (e.g. "pro" = 40-80h/week, "max" = 140-480h/week depending
         on tier). Should the Plan use these fields to show absolute remaining time
         rather than just percentages? This requires hardcoding plan ceiling values
         which may change without notice — the Plan stage should decide whether to
         expose this.

      4. WINDOWS CREDENTIAL MANAGER: On native Windows (not MSYS2/Git Bash), the
         OAuth token may be stored in Windows Credential Manager rather than the file.
         The research prompt states "macOS and Linux" as targets, so this may be
         out of scope — but the Plan stage should confirm.

      5. CACHE INVALIDATION: Should the 60-second cache be invalidated immediately
         after a USAGE_EXHAUSTED error is detected (to get a fresh resets_at before
         sleeping)? Yes, this seems correct — the Plan should specify this behaviour.
    </open_questions>
  </metadata>
</research>
