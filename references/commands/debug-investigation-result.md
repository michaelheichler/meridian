Use `{plugin-root}` as the literal plugin root resolved by the parent command. Replace it before running helpers or reading files.

<debug_session_persistence>
After the report-only investigation and any contract-scoped implementation complete, the main session runs verification and, only if it passes, creates the product fix commit. Capture the post-investigation HEAD before classifying the outcome:

```bash
HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")
```

Resolve one authoritative analysis-scoped `RESOLUTION_OBSERVATION` before persisting anything. Use the validated single `debugger_report.payload.resolution_observation`. Normalize it to exactly one of `already_fixed`, `needs_change`, or `inconclusive`. Do **not** infer `already_fixed` from free-text phrasing or from commit presence alone.

Before mapping `already_fixed` to `INVESTIGATION_OUTCOME=already_fixed`, verify fresh current evidence of actual resolution.
For selected known issues, UAT deviations, or accepted-process-exception details, accepted disposition alone is insufficient. Use `needs_change` when remediation remains, or `inconclusive` when you cannot apply a safe fix.
A no-commit session may still complete as `already_fixed` when fresh evidence proves the branch already contains a real fix.

Then compute the command-local three-way outcome. A new commit created now (`HEAD_BEFORE` != `HEAD_AFTER`) → `INVESTIGATION_OUTCOME=fixed_now`, no new commit now + `RESOLUTION_OBSERVATION=already_fixed` → `INVESTIGATION_OUTCOME=already_fixed`, no new commit now + `RESOLUTION_OBSERVATION=needs_change|inconclusive` → `INVESTIGATION_OUTCOME=no_fix_yet`.

Persist branch-specific investigation wording, do not collapse `already_fixed` and `no_fix_yet` into the same `"No fix applied"` text.

Build the investigation JSON payload:

```bash
INVESTIGATION_JSON=$(cat <<'ENDJSON'
{
  "mode": "investigation",
  "title": "{one-line bug summary}",
  "issue": "{bug description from user}",
  "hypotheses": [
    {
      "description": "{hypothesis description}",
      "status": "confirmed|rejected",
      "evidence_for": "{supporting evidence}",
      "evidence_against": "{contradicting evidence}",
      "conclusion": "{why chosen or rejected}"
    }
  ],
  "root_cause": "{confirmed root cause with file references}",
  "plan": "{chosen fix approach}",
  "implementation": "{summary of changes, or branch-specific text: fixed_now = changes applied now. already_fixed = no new changes were required because the current branch already contained the fix. no_fix_yet = investigation completed without applying a new fix in this run}",
  "changed_files": ["{file1}", "{file2}"],
  "commit": "{fixed_now = commit hash and message. already_fixed = 'Already fixed before this investigation, no new fix commit was required. If planning_tracking=commit, this completion path may create a planning-artifact commit.'; no_fix_yet = 'No new commit created during this investigation.'}"
}
ENDJSON
)
echo "$INVESTIGATION_JSON" | bash "{plugin-root}/scripts/write-debug-session.sh" "$session_file"
```

Then update session state from `INVESTIGATION_OUTCOME`. For `fixed_now`, set status to `qa_pending`:

```bash
bash "{plugin-root}/scripts/debug-session-state.sh" set-status .meridian qa_pending
```

For `already_fixed`, mark the investigation complete using the existing completed-session workflow:

```bash
bash "{plugin-root}/scripts/debug-session-state.sh" set-status .meridian complete
PG_SCRIPT="{plugin-root}/scripts/planning-git.sh"
if [ -f "$PG_SCRIPT" ]; then
  bash "$PG_SCRIPT" commit-boundary "complete debug session" .meridian/config.json
else
  echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
fi
```

For `no_fix_yet`, do **not** set `fix_applied`, keep the session status as `investigating`.
</debug_session_persistence>

Always clear the marker, regardless of outcome:

```bash
bash "{plugin-root}/scripts/delegated-workflow.sh" clear
```

Per @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md:

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Bug Investigation Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Mode:       {INVESTIGATION_MODE=parallel: "Competing Hypotheses (3 parallel)" + confirmed/rejected outcome per hypothesis | INVESTIGATION_MODE=serial: "Standard (single debugger)"}, report-only diagnosis followed by contract-scoped implementation when needed
  Issue:      {one-line summary}
  Root Cause: {from report}
  Outcome:    {fixed_now | already_fixed | no_fix_yet}
  Resolution: {fixed_now = "Applied now in {commit hash + message}" | already_fixed = "Already fixed on the current branch, no new fix commit was required. this completion path may still create a planning-artifact commit when planning_tracking=commit" | no_fix_yet = "No new commit created, further implementation still required"}

  Files Modified: {list}
```

If `SELECTED_TODO_MODE=true`, any numbered list captured before pickup is stale because helper pickup has already changed `STATE.md`. Use `SELECTED_TODO_START_JSON.pickup.status`, `.pickup.warning`, and `.pickup.auto_note` instead of inventing fresh numbered cleanup advice. Never tell the user to `remove N` for the selected todo, `/meridian:debug` already picked it up automatically. The helper auto note says the helper picked up the selected todo automatically. Emit `.pickup.auto_note` verbatim. Never cite a remaining todo number unless you first refresh through the existing snapshot/resolver flow. For default low-token UX, use unnumbered prose only, emit `.pickup.auto_note` and, when related backlog items may still exist, say `Rerun /meridian:list-todos for fresh numbering.` If `.pickup.status` is `partial` and `.pickup.warning` is non-empty, surface that warning explicitly.

**Discovered Issues:** If the Debugger reported pre-existing failures, out-of-scope bugs, or issues unrelated to the investigated bug, append after the result box. Cap the list at 20 entries. if more exist, show the first 20 and append `... and {N} more`:

```text
Discovered Issues:
  ⚠ testName (path/to/file): error message
  ⚠ testName (path/to/file): error message
Suggest: /meridian:todo <description> to track
```

This is **display-only**. Do NOT edit STATE.md, do NOT add todos, do NOT invoke /meridian:todo, and do NOT enter an interactive loop. The user decides whether to track these. If there are no discovered issues, omit the section.

If `INVESTIGATION_OUTCOME=no_fix_yet` (session status is still `investigating`): STOP with `➜ Next: /meridian:debug --resume -- Continue investigation and apply fix`. Do not enter inline QA.

If `INVESTIGATION_OUTCOME=already_fixed`, STOP with `➜ Debug session complete. Investigation confirmed the fix was already present.` Do not enter inline QA.

If `INVESTIGATION_OUTCOME=fixed_now` and session status is `qa_pending`, proceed to `<debug_inline_qa>` in the command (even if you displayed discovered issues above, they are informational only and do not gate the QA lifecycle).
