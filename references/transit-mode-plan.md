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

**Guard:** Initialized, roadmap exists, phase exists.
**Phase auto-detection:** First phase without PLAN.md. If every phase has a plan, STOP "All phases planned. Specify phase: `/meridian:transit --plan N`"
**Milestone path guard:** Check whether `{phases_dir}` contains `.meridian/milestones/`. If it does, STOP "Cannot plan inside archived milestones." Archived milestones are read-only.

**Steps:**
1. **Parse args:** Phase number (optional, auto-detected), --effort (optional, falls back to the configured value). Before planning, the main session derives `MILESTONE_SLUG` with `bash "{LINK}/scripts/derive-milestone-slug.sh" .meridian`, then runs `bash "{LINK}/scripts/milestone-branch.sh" start .meridian "$MILESTONE_SLUG"` to cover milestones that bootstrap created. Stop on failure and never delegate Git actions.
2. **Phase context:** Resolve CONTEXT path:
   ```bash
   CONTEXT_NAME=$(bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/resolve-artifact-path.sh context "{phase-dir}")
   ```
   If `{phase-dir}/${CONTEXT_NAME}` exists, include it in Lead agent context. If not, proceed without it. Users who want context run `/meridian:discuss {NN}` first.
3. **Research routing:** Run `bash "{LINK}/scripts/pipeline-research.sh" .meridian "{phase-dir}" "{effort}"` before planning, including turbo. Stop on helper failure. When `research_required=true`, run the Scout research step below before planning. Every non-turbo workflow effort retains its existing research step when no research artifact exists. `research_forced=true` also requires the emitted artifact before planning, including turbo. Otherwise turbo research stays optional, and existing research remains available to Lead.
   - The detected catalog route resolves only at Scout generation time. If that route is unavailable, generation fails clearly. Never skip required research silently.
   - Determine the next plan number `{MM}` and resolve artifact paths:
     ```bash
     RESOLVE_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/resolve-artifact-path.sh"
     NEXT_PLAN_NAME=$(bash "$RESOLVE_SCRIPT" plan "{phase-dir}")
     MM=$(echo "$NEXT_PLAN_NAME" | sed 's/^[0-9]*-\([0-9]*\)-.*/\1/')
     RESEARCH_NAME=$(bash "$RESOLVE_SCRIPT" phase-research "{phase-dir}")
     ```
    - Check for phase-wide research `{phase-dir}/${RESEARCH_NAME}` (preferred). If phase-wide does not exist, treat historical `{phase-dir}/{NN}-01-RESEARCH.md` as brownfield phase research only in the absence of higher-numbered per-plan research. Compute it with: `OTHER_PLAN_RESEARCH=$(find "{phase-dir}" -maxdepth 1 -name "{NN}-[0-9][0-9]*-RESEARCH.md" ! -name "{NN}-01-RESEARCH.md" -print -quit 2>/dev/null); if [ -f "{phase-dir}/{NN}-01-RESEARCH.md" ] && [ -z "$OTHER_PLAN_RESEARCH" ]; then BROWNFIELD_RESEARCH="{phase-dir}/{NN}-01-RESEARCH.md"; fi`. If `$OTHER_PLAN_RESEARCH` is non-empty, leave `$BROWNFIELD_RESEARCH` empty because multiple per-plan research files remain distinct and do not count as phase-wide research.
   - **If neither exists:** With `config_context_compiler=true`, compile Scout context first: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-context.sh {phase} scout {phases_dir}`. If the compiler produced `.context-scout.md`, include it in the Scout prompt and describe it as: "compiled context. It includes milestone scope decisions (decomposition rationale, scope boundaries, cross-phase key decisions) and phase operational context (goal, success criteria, matched requirements, conventions, changed files)."
     Read `prefer_teams` through `scripts/meridian-config.sh get .meridian prefer_teams`.
     - **Multi-stream research:** Use this path only for a phase with 2 to 4 facets that have no real dependency between them. It also requires a `prefer_teams` value other than `never`. For each facet, follow `references/agent-spawn-protocol.md`. Issue a separate solo `scout` command contract with that facet's exact `{phase-dir}/{NN}-RESEARCH-{facet-slug}.md` write allowance. Run the generic `scripts/agent-generator.sh scout` call and advance the contract to `dispatched`. Spawn all generated Scouts in one turn with their printed Agent-call parameters and no team or worktree fields. Each prompt covers one facet. The main session waits for all results, checks each file, and synthesizes canonical `{phase-dir}/${RESEARCH_NAME}` while retaining facet files as provenance.
     - **Single-Scout fallback:** Issue one solo `scout` contract with `{phase-dir}/${RESEARCH_NAME}` as its exact write allowance. Generate and spawn it through the same protocol. Use `Agent`, not the removed `Task` tool.
     - For either path, do not resolve or override model, effort, or turns. Stop and report any contract or generator failure verbatim. Evaluate relevant skills and MCP tools before composing each prompt. Render the prefix from `references/skill-activation-payload.md`. Include any available helper-emitted follow-up files.

    - **If exists (phase-wide or legacy single-file brownfield):** Record the RESEARCH.md path (phase-wide `${RESEARCH_NAME}` or brownfield `${BROWNFIELD_RESEARCH}`) for inclusion in the Lead prompt. The Lead prompt MUST include the directive `Read {research-path} for full research findings before planning.` Do NOT inline a summary of the research as a substitute. The Lead must read the file itself to get the complete, unabridged findings. Multiple per-plan research files are not phase-wide research. If no real phase-wide file exists, Scout must create `${RESEARCH_NAME}`. If new information emerges, Lead can update the phase-wide RESEARCH.md.
   - **On failure:** Stop when `research_forced=true`. Otherwise preserve the existing warning and continue planning without research.
    - **Authenticated live validation policy:** Scout can check authenticated/private read-only APIs with proven-safe Bash helper scripts or curl wrappers after preflight. Public/anonymous HTTP validation uses WebFetch. Do not route authenticated API validation through WebFetch. If a check is unsafe or mutating, or if Scout cannot prove it read-only, Scout must flag it with `⚠ REQUIRES AUTHENTICATED LIVE VALIDATION` for Dev/Debugger. Research that runs or defers live validation must include `## Live Validation Evidence` with `command_shape`, `exit_status`, `redacted_evidence`, `expected_shape`, `confidence`, and `limitations_or_deferred_reason`.
   - For turbo, skip optional research only. Required research still runs before the turbo planning shortcut.
4. **Research commit boundary (conditional):** Run this step only after a step 3 Scout spawn (new RESEARCH.md written):
   ```bash
  PG_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
   if [ -f "$PG_SCRIPT" ]; then
     bash "$PG_SCRIPT" commit-boundary "research phase {NN}" .meridian/config.json
   else
     echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping research git boundary commit." >&2
   fi
   ```
   With `planning_tracking=commit`, the helper commits a changed RESEARCH.md. This step does not run for pre-existing research or when no Scout ran.
5. **Context compilation:** With `config_context_compiler=true`, run `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-context.sh {phase} lead {phases_dir}`. If the compiler produced `.context-lead.md`, include it in Lead agent context. When including it in the Lead prompt, describe its contents: "Read `.context-lead.md` for compiled context. It includes milestone scope decisions (decomposition rationale, scope boundaries, cross-phase key decisions) and operational context (phase goal, success criteria, matched requirements, active decisions, research findings)."
6. **Turbo shortcut:** For effort=turbo, skip Lead. Resolve the plan filename:
   ```bash
   TURBO_PLAN=$(bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/resolve-artifact-path.sh plan "{phase-dir}")
   ```
   Read phase reqs from ROADMAP.md, create single lightweight plan as `${TURBO_PLAN}` in the phase directory.
7. **Other efforts:**

### Spawn Lead

  - Evaluate relevant skills and MCP tools, then render the prompt prefix from `references/skill-activation-payload.md`.
  - Follow `references/agent-spawn-protocol.md`. Issue a solo `lead` command contract for job `phase {NN} planning` with no write allowance. Run the generic `scripts/agent-generator.sh lead` call, advance the contract to `dispatched`, and use its printed Agent-call parameters and `SPAWN_READY` name exactly. Do not re-resolve model, effort, or turns.
  - The Lead returns complete plan content and proposed canonical filenames as evidence. The main session checks the dependency graph and persists the accepted PLAN files. Omit team and worktree fields.
### Lead prompt and result

   - **CRITICAL:** Step 3 can find or create a RESEARCH.md. In that case, include `Read {research-path} for full research findings before planning.` in the Lead prompt, where `{research-path}` is the per-plan or legacy path from step 3. The Lead must read the file itself. Do NOT substitute an inlined summary.
  - Required Lead guidance: "Execute can run plans as true team teammates or as serialized Dev subagents. Model real dependencies accurately. Same-wave plans must have no real dependency on each other and must modify disjoint file sets. Linear chains are valid for real dependencies. Do not invent independence to increase wave 1 size. Dependency-aware Execute uses teams only for real parallel delegate work, and false same-wave grouping can cause stale inputs or file conflicts."
   - **CRITICAL:** Include `Use resolve-artifact-path.sh to compute plan filenames: bash ${RESOLVE_SCRIPT} plan "{phase-dir}" --plan-number {MM}` in the Lead prompt, where `RESOLVE_SCRIPT` is the path from step 3. The script returns the canonical filename (for example `03-01-PLAN.md`). Call it once per plan with the plan number.
   - Display `◆ Spawning Lead agent...` -> `✓ Lead agent complete`.
8. **Normalize plan filenames:**
    ```bash
    NORM_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/normalize-plan-filenames.sh"
    if [ -f "$NORM_SCRIPT" ]; then
      bash "$NORM_SCRIPT" "{phase_dir}"
    fi
    ```
    This catches any misnamed files persisted from returned Lead content or created by turbo mode.
9. **Check output:** Check that PLAN.md has valid frontmatter (phase, plan, title, wave, depends_on, must_haves) and tasks. Check that wave deps are acyclic.
10. **Present:** Update STATE.md (phase position, plan count, status=Planned). Display the Phase Banner with its plan list and effort level. Only the generated agent contract supplies agent settings, never a static profile document:
    ```text
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   ◆ Phase {NN}: {name}
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Plans: {N}
     {plan}: {title} (wave {W}, {N} tasks)
   Effort: {effort}
   ```
11. **Planning commit boundary (conditional):**
   ```bash
  PG_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
   if [ -f "$PG_SCRIPT" ]; then
     bash "$PG_SCRIPT" commit-boundary "plan phase {NN}" .meridian/config.json
   else
     echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
   fi
   ```
   With `planning_tracking=commit`, the helper creates a local planning-artifact commit for changed artifacts. A remote push always requires main-session approval immediately before the shared mutation, regardless of `auto_push`.
12. **Cautious gate (autonomy=cautious only):** STOP after planning. Ask "Plans ready. Execute Phase {NN}?" Other levels auto-chain.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/extract-skill-follow-up-files.sh`
- `scripts/normalize-plan-filenames.sh`
- `scripts/planning-git.sh`
