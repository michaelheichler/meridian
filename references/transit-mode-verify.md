Use `{LINK}` as the literal plugin root resolved by the parent command. Replace it before running helpers or reading files.

## Main-session Decision Handoffs

Only the main session can call `AskUserQuestion`. Before each `AskUserQuestion`
call, the main session follows `references/meridian-brand-essentials.md`. A worker
that reaches a decision boundary returns the `user_decision_required` JSON from
`references/subagent-contracts.md`. The worker does not mutate state or claim a
todo until the main session responds. It also does not start the next stage
before that response. A declined choice keeps the state and reports the
documented Next Up command.

**Guard:** Initialized, phase has `*-SUMMARY.md` files.
If no SUMMARY.md exists, STOP "Phase {NN} has no completed plans. Run /meridian:transit first."
**Phase auto-detection:** First phase with `*-SUMMARY.md` but no canonical `*-UAT.md` (exclude `*-SOURCE-UAT.md` copies). If every phase has UAT results, STOP "All phases have UAT results. To re-run UAT for a specific phase, use `/meridian:transit --verify {NN}`."

**Inline execution (NON-NEGOTIABLE):** UAT is an interactive human conversation through AskUserQuestion CHECKPOINT prompts. Do NOT spawn a QA agent, Dev agent, or any subagent for UAT verification. Do NOT use TaskCreate to delegate UAT. The AskUserQuestion tool is only available to the orchestrator. Subagents cannot interact with the user, so delegating UAT to a subagent skips user input and produces auto-written UAT files without human judgment. Run the verify.md CHECKPOINT loop directly in this conversation, the same way UAT Remediation coordinates its stages inline.

**Steps:**
1. Resolve the final target phase from the selected Verify route before compiling context. An explicit `--verify N` target wins. Otherwise, use the phase chosen by state-driven Verify or auto-UAT routing. Set `PHASE_DIR` to that exact active phase directory. Check whether an upstream re-verification or QA-remediation transition in this turn already produced fresh verify context and UAT resume metadata for the same `PHASE_DIR`. If so, reuse that output. Otherwise run:
   ```bash
   SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n%s\n" "${CLAUDE_PLUGIN_ROOT:-}" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"
   [ "$SESSION_KEY" != root- ] || { echo "MERIDIAN: plugin root hash unavailable" >&2; exit 1; }
   L="{LINK}"
   P="/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"
   PDIR="$PHASE_DIR"
   PD=""
   _PD_START_TS=$(date +%s 2>/dev/null || echo 0)
   _phase_detect_cache_fresh() {
     local m=""
     [ -f "$P" ] || return 1
     m=$(stat -c %Y "$P" 2>/dev/null || stat -f %m "$P" 2>/dev/null || echo "")
     [ -n "$m" ] || return 1
     [ "$m" -ge "$_PD_START_TS" ] 2>/dev/null
   }
   _phase_detect_cache_retryable() {
     [ -z "$(printf '%s' "$PD" | tr -d '[:space:]')" ] || [ "$PD" = "phase_detect_error=true" ]
   }
   REAL_R=$(cd "$L" 2>/dev/null && pwd -P) || REAL_R=""
   if [ -n "$REAL_R" ]
   then
     bash "$REAL_R/scripts/ensure-plugin-root-link.sh" "$L" "$REAL_R" >/dev/null 2>&1 || true
   fi
   i=0
   while [ $i -lt 100 ]
   do
     if _phase_detect_cache_fresh
     then
       PD=$(cat "$P")
       break
     fi
     sleep 0.1
     i=$((i+1))
   done
   if _phase_detect_cache_retryable && [ -L "$L" ] && [ -f "$L/scripts/phase-detect.sh" ]
   then
     LOCK="/tmp/.meridian-phase-detect-live-${SESSION_KEY}.lock"
     i=0
     while [ $i -lt 100 ]
     do
       if _phase_detect_cache_fresh
       then
         PD=$(cat "$P")
         if ! _phase_detect_cache_retryable
         then
           break
         fi
       fi
       if mkdir "$LOCK" 2>/dev/null
       then
         PTMP="${P}.reader.$$.$RANDOM"
         PD=$(bash "$L/scripts/phase-detect.sh" 2>/dev/null) || PD=""
         if [ -n "$(printf '%s' "$PD" | tr -d '[:space:]')" ] && [ "$PD" != "phase_detect_error=true" ]
         then
           printf '%s\n' "$PD" > "$PTMP" 2>/dev/null && mv "$PTMP" "$P" 2>/dev/null || true
         fi
         rmdir "$LOCK" 2>/dev/null || true
         break
       fi
       sleep 0.1
       i=$((i+1))
     done
   fi
   [ -z "$(printf '%s' "$PD" | tr -d '[:space:]')" ] && _phase_detect_cache_fresh && PD=$(cat "$P")
   if _phase_detect_cache_retryable
   then
     PD="phase_detect_error=true"
   fi
   VERIFY_CONTEXT=$(
     if [ "$PD" = "phase_detect_error=true" ]; then
       echo "verify_context=unavailable"
     elif [ -d "$PDIR" ] && [ -f "$L/scripts/compile-verify-context-for-uat.sh" ]; then
       bash "$L/scripts/compile-verify-context-for-uat.sh" "$PDIR" 2>/dev/null || echo "verify_context_error=true"
     else
       echo "verify_context_error=true"
     fi
   )
   UAT_RESUME=$(
     if [ -d "$PDIR" ] && [ -f "$L/scripts/extract-uat-resume.sh" ]; then
       bash "$L/scripts/extract-uat-resume.sh" "$PDIR" 2>/dev/null || echo "uat_resume=error"
     else
       echo "uat_resume=unavailable"
     fi
   )
   ```
   This runtime call is route-local. Do not compile verify context while parsing inputs or routing to Plan, Discuss, Scope, Archive, or any other non-Verify mode. Read `{LINK}/commands/verify.md` and use `VERIFY_CONTEXT` plus `UAT_RESUME` as the active protocol context. **Error guard:** Check `VERIFY_CONTEXT` for `verify_context_error=true` or `verify_context=unavailable`. On either value, display: "⚠ Verify context compilation failed. Run `bash "{LINK}/scripts/compile-verify-context-for-uat.sh" .meridian/phases/{NN}-{slug}` manually to debug." STOP. Do NOT improvise by scanning PLAN/SUMMARY files manually in this routed path.
2. Execute the verify.md steps inline in this conversation. Specifically, generate test scenarios (verify.md Step 4). Then run the CHECKPOINT loop (verify.md Step 5), presenting one test at a time via AskUserQuestion. Wait for the user's response before proceeding to the next test. Use the active `VERIFY_CONTEXT` aggregation and `UAT_RESUME` metadata for the target phase. Pass the full UAT resume metadata through to the verify protocol. Include `uat_resume_scenario`, `uat_resume_expected`, and any present summary-deviation source fields. This metadata lets verify.md ask the first resumed checkpoint without re-reading the UAT file. After each persisted answer, verify.md re-runs `extract-uat-resume.sh` and uses the refreshed deterministic fields for the next checkpoint. Do NOT read individual PLAN/SUMMARY files or scan-parse UAT.md for resume state.
3. Display results per verify.md output format.
4. **UAT Remediation Auto-Continuation:** This step applies only to a verify.md result that emitted `remediation_continue=true`. That signal appears only with `verify_scope=remediation` AND `status=issues_found` AND a run in orchestrated mode from transit.md. If `remediation_continue` was not set (first-time UAT, complete result, or standalone verify), skip this step. The command ends after step 3.

   **Prepare the next remediation round through the safe transition helper:** Run `prepare-reverification.sh` exactly once for this transition. This helper finalizes and checks the active UAT before state mutation and applies the UAT remediation round cap. If nothing blocks the transition, the helper then performs the next-round transition. A direct `needs-round` call is not the transition path here because it can mutate `.uat-remediation-stage` before the current UAT is terminal.

   ```bash
   _prepare_output=$(bash "{LINK}/scripts/prepare-reverification.sh" "{phase-dir}" 2>&1)
   _prepare_status=$?
   ```

   **If `prepare-reverification.sh` exits nonzero:** Display the helper output and STOP. Do not re-enter remediation with stale state.

   **If `_prepare_output` is empty or malformed:** STOP. Required recognized keys are one of `archived=...` or `skipped=...`. Valid `skipped` values are `already_archived`, `ready_for_verify`, or `cap_reached`. Malformed prepare output means the helper did not prove the transition safe.

   Parse the helper output:
   ```bash
   _archived=$(printf '%s\n' "$_prepare_output" | awk -F= '/^archived=/{print $2; exit}')
   _skipped=$(printf '%s\n' "$_prepare_output" | awk -F= '/^skipped=/{print $2; exit}')
   _round=$(printf '%s\n' "$_prepare_output" | awk -F= '/^round=/{print $2; exit}')
   _max_rounds=$(printf '%s\n' "$_prepare_output" | awk -F= '/^max_rounds=/{print $2; exit}')
   ```

   **If `_skipped=cap_reached`:** Display the cap-reached banner and STOP. Use `max_rounds={N}` from the helper output:
   ```text
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     Reached maximum UAT remediation rounds ({_max_rounds}).
     Review issues manually or adjust max_uat_remediation_rounds
     in config.json.
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ```
   Do NOT re-enter remediation. STOP.

   **Resolve the new round:** Prefer the `round=` value that `prepare-reverification.sh` emits. If `round=` is absent after a successful prepare, read the current round as a read-only fallback:
   ```bash
   if [ -z "$_round" ]; then
     _round=$(bash "{LINK}/scripts/uat-remediation-state.sh" current-round "{phase-dir}" 2>/dev/null)
   fi
   ```
   If `_round` is empty after both attempts, treat the prepare output as malformed and STOP.

   Display the transition banner and re-enter UAT Remediation mode inline:
   ```text
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     Re-verification found {N} issue(s). Continuing to Round {_round}.
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ```
   Where `{N}` is the issue count from the `remediation_continue` signal (`issues={N}`).
   Re-enter UAT Remediation mode (above) for the same `PHASE_DIR`. The prepare helper set the remediation state to `research` for the new round. The UAT Remediation mode's step 4 (`get-or-init`) will resume correctly from the `research` stage.

  **Continuation loop behavior:** The re-entered UAT Remediation mode chains into Verify mode after its execute stage completes (existing behavior). If that verification again finds issues, verify.md emits `remediation_continue=true` again, and this step 4 re-checks the UAT remediation round cap. This creates the auto-continuation loop. If `max_uat_remediation_rounds` resolves to a positive integer, that value bounds the loop. Otherwise the loop has no bound. If context window limits prevent continuation mid-loop, the fallback remediation summary section remains the escape hatch.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/compile-verify-context-for-uat.sh`
- `scripts/ensure-plugin-root-link.sh`
- `scripts/extract-uat-resume.sh`
- `scripts/prepare-reverification.sh`
- `scripts/uat-remediation-state.sh`
