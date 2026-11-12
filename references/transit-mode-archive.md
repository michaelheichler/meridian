## Main-session Decision Handoffs

Only the main session can call `AskUserQuestion`. Before each `AskUserQuestion`
call, the main session follows `references/meridian-brand-essentials.md`. A worker
that reaches a decision boundary returns the `user_decision_required` JSON from
`references/subagent-contracts.md`. The worker does not mutate state or claim a
todo until the main session responds. It also does not start the next stage
before that response. A declined choice keeps the state and reports the
documented Next Up command.

## Generated Agent Authority

For every agent spawn, follow `references/agent-spawn-protocol.md`. The main
session issues the command contract, runs `scripts/agent-generator.sh`, and
uses its `SPAWN_READY` name and printed settings exactly. Generated output is
the sole authority for name, model, effort, and turn limit. Do not select them
from a static model profile. Every spawn below uses the generic contract-issuing
generator protocol.

**Guard:** Initialized, roadmap exists.
- If there is no roadmap, STOP "No milestones configured. Run `/meridian:transit` to bootstrap."
- If there is no work (no SUMMARY.md files), STOP "Nothing to ship."

**Hard UAT gate (always, non-bypassable):**
Before any audit/bypass handling, run:
```bash
bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/archive-uat-guard.sh
```
If the exit code is 2, STOP. Unresolved UAT (active or milestone) blocks archive regardless of `--skip-audit` or `--force`.

**Hard state-consistency gate (always, non-bypassable):**
After the UAT gate passes, run:
```bash
bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-state-consistency.sh .meridian --mode archive
```
If the exit code is non-zero, STOP. If the exit code is 2, state misalignment at archive means the archived milestone record can be unreliable. Phase counts, completion markers, or project metadata can be inconsistent. Surface the JSON output's `failed_checks` array so the user can fix the drift before retrying. For any other non-zero exit, treat the verifier as failed unexpectedly and do not proceed with archive.

**Pre-gate audit (unless --skip-audit or --force):**
Run 7-point audit matrix:
1. Roadmap completeness. Every phase has a real goal (not TBD/empty).
2. Phase planning. Every phase has >= 1 PLAN.md.
3. Plan execution. Every PLAN.md has SUMMARY.md.
4. Execution status. Every SUMMARY.md has `status: complete`.
5. Verification. Authoritative QA verification exists and is fresh PASS. Missing=WARN, failed=FAIL. After QA remediation reaches `done`, the authoritative artifact is the round-scoped `R{RR}-VERIFICATION.md`. Never reuse the frozen phase-level VERIFICATION.md.
6. UAT status. Any `*-UAT.md` with `status: issues_found` = FAIL. Remediate unresolved UAT issues before archiving.
7. Requirements coverage. Req IDs in roadmap exist in REQUIREMENTS.md.
FAIL -> STOP with remediation suggestions. WARN -> proceed with warnings.

**Steps:**
1. **Derive milestone slug deterministically (do NOT invent a slug):**
   ```bash
   MILESTONE_SLUG=$(bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/derive-milestone-slug.sh .meridian)
   ```
  This reads ROADMAP.md phase names and outputs a numbered kebab-case slug (for example, `01-setup-api-layer`). Keep this milestone slug separate from any custom git tag passed via `--tag`. **Never use a hardcoded slug like "default". Always use the script output.**
2. Parse the args --tag=vN.N.N (custom tag), --no-tag (skip), and --force (skip non-UAT audit).
3. Compute the summary from ROADMAP (phases), SUMMARY.md files (tasks/commits/deviations), and REQUIREMENTS.md (satisfied count).
4. **Rolling summary (conditional)**: If `rolling_summary=true` in settings:
   ```bash
   bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-rolling-summary.sh \
     .meridian/phases .meridian/ROLLING-CONTEXT.md 2>/dev/null || true
   ```
   Compiles final rolling context before artifacts move to milestones/. Fail-open.
   When `rolling_summary=false`, skip.
5. Archive: `mkdir -p .meridian/milestones/{SLUG}`. Move ROADMAP.md, STATE.md, and phases/ to milestones/{SLUG}/. If `.meridian/CONTEXT.md` exists, move it to milestones/{SLUG}/CONTEXT.md. Use the **Write** tool (not Bash) to create `.meridian/milestones/{SLUG}/SHIPPED.md`. This ensures PostToolUse hooks fire for artifact tracking. Delete stale RESUME.md.
5b. **Persist project-level state:** After archiving, run:
   ```bash
   bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/persist-state-after-ship.sh \
     .meridian/milestones/{SLUG}/STATE.md .meridian/STATE.md "{PROJECT_NAME}"
   ```
   This extracts project-level sections (Todos, Decisions, Blockers, Codebase Profile) from the archived STATE.md and writes a fresh root STATE.md. Milestone-specific sections (Current Phase, Activity Log, Phase Status) stay in the archive only. Fail-open. If the script fails, warn but continue.
6. Planning commit boundary (conditional):
   ```bash
  PG_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
   if [ -f "$PG_SCRIPT" ]; then
     bash "$PG_SCRIPT" commit-boundary "archive milestone {SLUG}" .meridian/config.json
   else
     echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
   fi
   ```
   Run this BEFORE branch merge/tag so a commit records the shipped planning state.
7. The main session runs `bash "{LINK}/scripts/milestone-branch.sh" complete .meridian "{SLUG}"`, using the exact slug from step 1. On `branch_action=offer_merge`, offer the human a merge from the emitted `branch` into `merge_target`. Only after approval, require a clean tree, switch to that target and merge the milestone branch with `--no-ff`. After a successful managed merge, run `bash "{LINK}/scripts/milestone-branch.sh" finish .meridian "{SLUG}"` to remove its merged branch and state file so the slug can start again. A declined offer retains both for later completion. On `disabled` or `no_managed_branch`, preserve the legacy behavior, merge an existing `milestone/{SLUG}` branch with `--no-ff` without the new approval offer, or skip when no branch exists. Abort and report any merge conflict. Helper failure stops archive. Never delegate Git actions.
8. Git tag. Unless --no-tag, `git tag -a {tag} -m "Shipped milestone: {name}"`. Default: `milestone/{SLUG}`.
9. Regenerate CLAUDE.md. Follow `references/agent-spawn-protocol.md`. Issue a solo `docs` command contract for job `regenerate CLAUDE.md for milestone {SLUG} ship` with `CLAUDE.md` as its exact write allowance. Run the generic `scripts/agent-generator.sh docs` call, advance the contract to `dispatched`, and capture its `SPAWN_READY` name. Render the prompt prefix from `references/skill-activation-payload.md`.
   Task it: "Update root CLAUDE.md's `## Active Context` section for the milestone {SLUG} that shipped. Remove references to now-shipped work. Preserve all non-MERIDIAN content verbatim. Only replace canonical MERIDIAN-managed sections already present in the file."
   Use the generated name and Agent-call parameters exactly as printed. Omit team and worktree fields. Do not re-resolve or override the model. Keep the generated effort and turns unchanged.
   Wait for completion before continuing to step 9b.
9b. Post-archive hook (non-blocking): after successful archive completion, run:
   ```bash
   bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/post-archive-hook.sh "{SLUG}" ".meridian/milestones/{SLUG}" "{tag}" .meridian/config.json
   ```
   Use the tag selected in step 8. When the run used `--no-tag`, use an empty third argument instead. Repos without `hooks.post_archive` configured no-op through the dispatcher. Any warnings are non-blocking.
10. Present the Phase Banner with metrics (phases, tasks, commits, requirements, deviations), archive path, tag, branch status, and memory status. Run `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/suggest-next.sh transit`.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/archive-uat-guard.sh`
- `scripts/compile-rolling-summary.sh`
- `scripts/derive-milestone-slug.sh`
- `scripts/persist-state-after-ship.sh`
- `scripts/planning-git.sh`
- `scripts/post-archive-hook.sh`
- `scripts/suggest-next.sh`
