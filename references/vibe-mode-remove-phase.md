## Main-session Decision Handoffs

Only the main session can call `AskUserQuestion`. Before each `AskUserQuestion`
call, the main session follows `references/lbwc-brand-essentials.md`. A worker
that reaches a decision boundary returns the `user_decision_required` JSON from
`references/subagent-contracts.md`. The worker does not mutate state or claim a
todo until the main session responds. It also does not start the next stage
before that response. A declined choice keeps the state and reports the
documented Next Up command.

**Guard:** Initialized. Requires phase number.
- If the number is missing, STOP "Usage: `/lbwc:vibe --remove <phase-number>`"
- If the phase is not found, STOP "Phase {NN} not found."
- If the phase has work (PLAN.md or SUMMARY.md), STOP "Phase {NN} has artifacts. Remove plans first."
- If the roadmap marks the phase [x], STOP "Cannot remove completed Phase {NN}."

**Steps:**
1. Parse the args. Extract the phase number, confirm it is valid, and look up the name/slug.
2. Confirm with the user. Display the phase details and ask for confirmation. If the user does not confirm, STOP.
3. Remove dir: `rm -rf .lbwc-planning/phases/{NN}-{slug}/`
4. Renumber FORWARD. For each phase > removed, rename dir {NN} -> {NN-1}, rename internal files, update frontmatter, and update depends_on.
5. Update ROADMAP.md. Remove the phase entry + details, renumber subsequent entries, update deps, and update the progress table.
6. If `.lbwc-planning/CONTEXT.md` exists, rewrite it to reflect the updated milestone decomposition (phase count/grouping, ordering, scope coverage, and requirement mapping). Preserve project-level key decisions and deferred ideas where still valid.
7. Update STATE.md phase total: `bash /tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/update-phase-total.sh .lbwc-planning --removed {NN}` (where {NN} is the removed phase number from step 1).
8. **Phase mutation commit boundary (conditional):**
   ```bash
  PG_SCRIPT="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
   if [ -f "$PG_SCRIPT" ]; then
     bash "$PG_SCRIPT" commit-boundary "remove phase {NN}" .lbwc-planning/config.json
   else
     echo "⚠ LBWC: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
   fi
   ```
   If `.lbwc-planning/` changed, `planning_tracking=commit` commits it. Other modes no-op.
9. Present the Phase Banner with renumber count, phase changes, file list, and Next Up.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/planning-git.sh`
- `scripts/update-phase-total.sh`
