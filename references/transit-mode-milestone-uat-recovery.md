## Main-session Decision Handoffs

Only the main session can call `AskUserQuestion`. Before each `AskUserQuestion`
call, the main session follows `references/meridian-brand-essentials.md`. A worker
that reaches a decision boundary returns the `user_decision_required` JSON from
`references/subagent-contracts.md`. The worker does not mutate state or claim a
todo until the main session responds. It also does not start the next stage
before that response. A declined choice keeps the state and reports the
documented Next Up command.

**Guard:** `milestone_uat_issues=true` from phase-detect.sh. Active phases dir is empty/all_done but UAT issues remain unresolved in the latest shipped milestone.

This mode handles a milestone that went to the archive with unresolved UAT issues (for example, because older versions had no audit gate).

**Steps:**
1. After routing selects milestone recovery, extract milestone UAT issues with this route-local block:
   ```bash
   MILESTONE_UAT_CONTEXT=$(
     SESSION_KEY="${CLAUDE_SESSION_ID:-default}"
     L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"
     P="/tmp/.meridian-phase-detect-${SESSION_KEY}.txt"
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
       echo "milestone_extract_unavailable=true"
     elif printf '%s' "$PD" | grep -q '^---MILESTONE_UAT_EXTRACT_START---$'
     then
       printf '%s\n' "$PD" | awk '
         /^---MILESTONE_UAT_EXTRACT_START---$/ {
           found=1
           next
         }
         /^---MILESTONE_UAT_EXTRACT_END---$/ {
           exit
         }
         found {
           print
         }
       '
     else
       MS_UAT=$(printf '%s' "$PD" | grep '^milestone_uat_issues=' | head -1 | cut -d= -f2)
       if [ "$MS_UAT" = "true" ]
       then
         echo "milestone_extract_unavailable=true"
       else
         echo "not_milestone_recovery"
       fi
     fi
   )
   ```
   Each extracted block starts with `milestone_phase_dir=<path>` followed by `extract-uat-issues.sh` output (header line plus issue lines). Do NOT read UAT files from the milestone. All issue data is already in `MILESTONE_UAT_CONTEXT`.
   If `milestone_uat_count` > 1, multiple blocks are present, one per affected phase separated by `---`. If `milestone_uat_count` = 1, a single block is present.
2. Display the unresolved issues to the user with milestone context (milestone slug, affected phase count, severity mix). Then call AskUserQuestion with three options:
   - **"Create remediation phases"** (for `milestone_uat_major_or_higher=true`, set `isRecommended`): Create one remediation phase per affected milestone phase. Auto-populate each phase goal from the UAT issue descriptions. Route to Plan mode for the first created phase.
   - **"Start fresh with new work"**: Acknowledge the stale UAT issues and mark them as acknowledged (`.remediated`). The markers stop them from re-triggering archive blocking. Then treat the state as all_done and proceed. The user can define new work via `/meridian:transit` with arguments.
   - **"Not now"**: Skip milestone UAT recovery without marking anything. The unresolved UAT issues will re-trigger on the next `/meridian:transit` invocation.
   **`--yolo` exception:** For a `--yolo` invocation, skip the AskUserQuestion and auto-select "Create remediation phases" (the recommended action).
3. If the user chooses remediation, create one remediation phase per affected milestone phase via the script:
   ```bash
   IFS='|' read -ra UAT_DIRS <<< "$milestone_uat_phase_dirs"
   for dir in "${UAT_DIRS[@]}"; do
     bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/create-remediation-phase.sh .meridian "$dir"
   done
   ```
   The script also writes a `.remediated` marker in each source milestone phase dir to prevent re-triggering on future sessions. After creating all phases, write a ROADMAP.md and update STATE.md reflecting the remediation phases.
   **Remediation commit boundary (conditional):**
   ```bash
  PG_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
   if [ -f "$PG_SCRIPT" ]; then
     bash "$PG_SCRIPT" commit-boundary "create milestone remediation phases" .meridian/config.json
   else
     echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
   fi
   ```
   Then route to Plan mode for the first phase.
4. If the user chooses start-fresh, persist acknowledgement markers for all affected archived phases before continuing:
   ```bash
   TARGET_PHASE_DIRS="$milestone_uat_phase_dirs"
   if [ -z "$TARGET_PHASE_DIRS" ] && [ "$milestone_uat_phase_dir" != "none" ]; then
     TARGET_PHASE_DIRS="$milestone_uat_phase_dir"
   fi
   bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/mark-milestone-remediated.sh .meridian "$TARGET_PHASE_DIRS"
   ```
   **Re-route after marking (NON-NEGOTIABLE):** The pre-computed routing state is now stale because `.remediated` markers changed on-disk state. Re-run phase-detect to discover existing phases or new-work eligibility:
   ```bash
   FRESH_PD=$(bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/phase-detect.sh 2>/dev/null)
   ```
   **Error guard:** For an empty `FRESH_PD`, or one that contains `phase_detect_error=true`, display "⚠ Phase detection failed after marking milestones. Run `/meridian:transit` again." and STOP.
   **Re-trigger guard:** Apply this guard only while `FRESH_PD` still shows `milestone_uat_issues=true`. Compare `milestone_uat_slug` from `FRESH_PD` with the slug that this step processed (the original `milestone_uat_slug` from the pre-computed state). If the slugs match, the marking failed for this milestone. Display "⚠ MERIDIAN failed to write some milestone UAT markers. Manually create `.remediated` files in the affected phase dirs, then run `/meridian:transit`." and STOP (this prevents an infinite loop). If the slugs do NOT match, a different older milestone still carries unresolved UAT. Let routing continue. The priority table handles that milestone, and it can route to Milestone UAT Recovery for it.
   Otherwise, parse all routing variables from `FRESH_PD`, such as `next_phase_state`, `phase_count`, `config_auto_uat`, and `has_unverified_phases`. Apply the **full priority table above** (priorities 1 to 11) to determine the correct mode. Route inline in the same turn. Key outcomes:

   **Verification and remediation outcomes:**
   - `needs_uat_remediation` → UAT Remediation mode
   - `needs_reverification` → Re-verify mode
   - `milestone_uat_issues=true` (different milestone) → Milestone UAT Recovery mode
   - `needs_verification` → Verify mode (auto_uat)

   **Planning and milestone outcomes:**
   - `needs_discussion` → Discuss mode
   - `needs_plan_and_execute` → Plan + Execute mode
   - `needs_execute` → Execute mode
   - `phase_count=0` → Scope mode
   - `all_done` → Archive mode
   This list is illustrative. Always defer to the full priority table. While phases already exist, do NOT stop and ask the user what they want to build.
5. If the user chooses "Not now", display "Skipping milestone UAT recovery. Run `/meridian:transit` again to address these issues." and STOP. Write no `.remediated` markers. The unresolved UAT issues will re-trigger on the next `/meridian:transit` invocation.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/create-remediation-phase.sh`
- `scripts/ensure-plugin-root-link.sh`
- `scripts/mark-milestone-remediated.sh`
- `scripts/planning-git.sh`
