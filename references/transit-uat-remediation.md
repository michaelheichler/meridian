Use `{LINK}` as the literal plugin root resolved by the parent command. Replace it before running helpers or reading files.

# Meridian Transit UAT Remediation

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


Loaded via `@${CLAUDE_PLUGIN_ROOT}/references/transit-uat-remediation.md` from `commands/transit.md` to run the `/meridian:transit` UAT remediation stage machine.

## Entry, Stage Resolution, and Issue Ranking (TRANSIT-UAT-01)

**Guard:** Initialized, target phase has `*-UAT.md` with `status: issues_found`.

**Execution model:** This mode runs inline. The orchestrator manages stage transitions (steps 1-5) and spawns agents for the work within each stage (step 6). The three stages (research, plan, execute) are sequential steps of this conversation, not delegated tasks. Do not decompose them into TaskCreate items.

**Chain state tracking:** This mode uses `{LINK}/scripts/uat-remediation-state.sh` to persist the current stage of the remediation chain on disk. This state file lets the chain resume correctly after compaction or session restart. The chain does NOT rely on prompt memory alone.

**Steps:**
1. For `next_phase_state=needs_uat_remediation`, resolve the target phase from pre-computed state (`next_phase`, `next_phase_slug`). Set `PHASE_DIR` to the resolved phase directory path.
   **Milestone path guard (NON-NEGOTIABLE):** A `PHASE_DIR` that contains `.meridian/milestones/` (for example `.meridian/milestones/*/phases/`) points to an archived milestone. In that case, STOP. UAT Remediation operates only on active phases in `.meridian/phases/`. Display "⚠ UAT issues found in archived milestone, not active phases. Routing to Milestone UAT Recovery." Then route to Milestone UAT Recovery mode instead.
2. Read the active UAT artifact exactly once. If the pre-computed state has `uat_file`, use it. It is phase-relative to `PHASE_DIR` (for example `03-UAT.md` or `remediation/uat/round-01/R01-UAT.md`). If `uat_file=none` or the computed path does not exist, resolve the active UAT artifact from `PHASE_DIR`. Use one deterministic fallback order for this (current round-dir UAT first, phase-root fallback). If no active UAT artifact exists, STOP and display "⚠ Phase {NN} routes to UAT remediation but has no active UAT artifact."
   **Single-read rule (NON-NEGOTIABLE):** Use that single UAT read as the source of truth for issue descriptions and severities. It is also the source of truth for current remediation scope. Do NOT shell out to `extract-uat-issues.sh` for active-phase routing.
   **Round-dir nuance:** At the start of a new remediation round, the active artifact can still be the latest previous-round UAT. For example, step 4 returns `round=02` while the active file is `remediation/uat/round-01/R01-UAT.md`. This case is normal. Treat the artifact you read here as the current source report until a newer UAT exists.
3. Normalize the current issue list from the UAT read. For each failing test or discovered issue, capture `ID`, `SEVERITY`, and `DESCRIPTION`. Treat this normalized issue list as source-of-truth scope. Do NOT ask the user to restate issues already recorded in UAT.
4. **Resolve remediation stage (single call):**
   ```bash
   bash "{LINK}/scripts/uat-remediation-state.sh" get-or-init "$PHASE_DIR" "major"
   ```
   For `uat_issues_major_or_higher=true`, use `major`. Otherwise use `minor` for the initial entry call.
   **Run directly (do NOT capture with `$()`).**
   - Both resume and init paths emit **plan metadata** after the stage line:
     ```text
     round=RR: zero-padded current round number (e.g., 01)
     round_dir=<path>: absolute host-repository path to the round directory
     research_path=<path>: absolute host-repository path to existing RESEARCH.md (empty if none)
     plan_path=<path>: absolute host-repository path to existing PLAN.md (empty if none)
     summary_path=<path>: absolute host-repository path where the agent writes SUMMARY.md
     ```
     **Use these values directly:** do NOT glob `*-PLAN.md` or search for RESEARCH.md files. The script pre-computes all paths from the phase directory (with legacy phase-root fallback for brownfield projects).
    <uat_remediation_artifact_contract>
    `round_dir`, `research_path`, `plan_path`, and `summary_path` are absolute paths in the host repository. Claude Code can run subagents from `.claude/worktrees/agent-*` sidechain CWDs. Pass these exact paths to every Scout/Lead/Dev prompt and never rewrite them relative to the current CWD. Do not accept artifacts written under `.claude/worktrees/agent-*` as valid remediation artifacts.
    In migrated `layout=legacy` projects, non-empty `research_path` or `plan_path` can be an absolute phase-root artifact selected by `uat-remediation-state.sh`. Verify that exact metadata path directly instead of rewriting it to `round_dir` or searching for alternatives.
    </uat_remediation_artifact_contract>
    <uat_remediation_spawn_contract>
    The Research → Plan → Execute (or Fix) list is visible session progress only. Do not create TaskCreate or TaskUpdate records for stages.
    Real work follows `references/agent-spawn-protocol.md`. Research and planning use sequential solo contracts. Execution uses one contracted pair or trio at a time.
    Use the exact absolute host paths returned by remediation state. This keeps every worker on the same `.meridian/.../remediation/uat/...` artifacts.
    </uat_remediation_spawn_contract>
    <examples>
    <example type="anti-pattern" label="WRONG, stage progress via delegated task manager">
    TaskCreate("Research Phase 03 UAT remediation") → TaskUpdate("Plan", completed) → TaskCreate("Execute"). This chain creates stage trackers outside the main session's visible progress list.
    </example>
    <example type="correct" label="RIGHT, visible stage progress">
    Progress shows Research=in-progress, Plan=not-started, Execute=not-started. After research passes verification, progress shows Research=completed, Plan=in-progress, Execute=not-started.
    </example>
    <example type="correct" label="RIGHT, delegated Dev work unit">
    Issue the current task's exact contract, then generate its pair or trio. Spawn every generated member with the printed parameters. Include absolute artifacts exactly as returned by state metadata:
    Plan: /repo/.meridian/phases/03-example/remediation/uat/round-01/R01-PLAN.md
    Summary: /repo/.meridian/phases/03-example/remediation/uat/round-01/R01-SUMMARY.md
    </example>
    </examples>
   - For a stage already on disk (resume after compaction/restart), the script returns the stage word + plan metadata with no side effects.
   - If no stage existed (first entry into remediation), the script initializes the stage file and creates the `remediation/uat/round-01/` directory. It also pre-seeds the phase `{NN}-CONTEXT.md`. It returns the stage word + plan metadata + `---CONTEXT---` separator with the full pre-seeded context content. **Use this content directly as your remediation context. Do NOT separately read UAT.md or `{NN}-CONTEXT.md` files.**
   - If the returned stage is `done`, UAT remediation already completed for this phase. Display "Remediation already completed. Run `/meridian:transit` to re-verify." STOP.
    **Visible progress list (NON-NEGOTIABLE ordering and state):** Create a visible progress list immediately after you resolve the stage. For the major path, the items are (1) Research, (2) Plan, and (3) Execute, in **exactly this order**. For the minor path, the only item is (1) Fix. **Item numbering must match stage order.** Research is always #1, Plan is #2, and Execute is #3. Never reorder items. This list is a progress display for the user. The execution stage below spawns the agents for each stage. Do not represent Research, Plan, Execute, or Fix as TaskCreate/TaskUpdate items.
   - **Initial creation:** For a resolved stage of `research`, mark Research as in-progress, and mark Plan and Execute as not-started. If the resolved stage is `plan` (resume case), mark Research as completed, Plan as in-progress, Execute as not-started. If `execute`, mark Research and Plan as completed, Execute as in-progress.
   - **Same-session progression:** After a stage completes and you advance to the next stage within the same session, immediately update the visible progress list. For example, research completes → advance → start plan. Mark the completed stage as completed and the new stage as in-progress. Do NOT defer updates or recreate the list from scratch.
   - **Final stage:** After the last stage completes, mark every visible progress item as completed before you present the summary.
5. **Recurrence analysis and priority ranking:**
   Use `round=RR` from step 4 as the **current remediation round** for stage management.

   Derive `active_uat_round` from the single step-2 UAT artifact:
   - `remediation/uat/round-{NN}/R{NN}-UAT.md` → `active_uat_round={NN}`
   - phase-root `*-UAT.md` → the active report round at the phase root. Without archived round files, this round is 1. Otherwise the root report round comes after the archived round files already on disk.

   **Important:** `active_uat_round` can be **less than `RR`** at the start of a new remediation round because the new round has no UAT yet. Do NOT assume the active UAT artifact belongs to the current remediation round.

   **Post-route enrichment:** For the recurrence scan of earlier UAT artifacts, read only the archived artifacts for this phase (flat `*-UAT-round-*.md` or round-dir `remediation/uat/round-*/R*-UAT.md`). **Exclude the active step-2 UAT artifact itself from the scan.** Build `FAILED_IN_ROUNDS` from the matching archived rounds plus `active_uat_round`. If no earlier matches exist, default each current issue to `FAILED_IN_ROUNDS={active_uat_round}`, **never** default to `RR` when the active artifact is a previous-round UAT.

  **Phase-level escalation:** For `RR >= 3`, force ALL issues through `research → plan → execute` regardless of severity. If the persisted stage from step 4 is `fix`, replace the quick-fix visible progress list before continuing. Use the major-path visible progress list (`Research`, `Plan`, `Execute`) instead.

   **Per-test priority ranking:** Rank issues by `failure_count` descending, tests that failed the most recorded UAT rounds get investigated and fixed FIRST. When presenting issues to Scout (research stage) and Lead (plan stage), reorder by `failure_count` descending and annotate:
   - `⚠ RECURRING (failed in N recorded rounds): ID|SEVERITY|DESCRIPTION` for tests with `failure_count >= 2`
   - `ID|SEVERITY|DESCRIPTION` (no annotation) for first-time failures

   **Scout research prompt for recurring issues** MUST include: *"{ID} failed in {N} recorded UAT rounds (rounds: {FAILED_IN_ROUNDS}). Current source artifact round: {active_uat_round}. Current remediation round: {RR}. Prior fixes have not resolved this. Investigate WHY previous fixes failed before you propose a new approach. Examine the actual data flow, not only the symptoms."*

   **Lead planning prompt for recurring issues** MUST include: *"Prioritize recurring failures. {ID} failed in {N} recorded UAT rounds. Allocate more plans/effort to this issue than to first-time failures."*

## Stage Execution Contract (TRANSIT-UAT-02)

Execute the current stage based on `STAGE`.

- **File read rule:** Do NOT re-read the active `{phase}-UAT.md` artifact unless step 5 requires earlier archived rounds for recurrence enrichment. Use the single step-2 UAT read as the active-round source of truth. If step 5 scans archived rounds, exclude that active artifact from the scan. Do NOT read `{phase}-CONTEXT.md`. Step 4 already emitted the remediation context for the cases that need it.
- **Round metadata prohibition:** Do NOT glob `*-PLAN.md`, search for `*-RESEARCH.md`, or infer summary locations. Use the pre-computed `round`, `round_dir`, `research_path`, `plan_path`, and `summary_path` values from step 4. If a subagent reports success but the deterministic validator below fails, treat the stage as incomplete and STOP without advancing state.
- **Subagent no-tool circuit breaker (NON-NEGOTIABLE):** Apply this rule at every UAT remediation Scout, Lead, or Dev subagent return site below. Follow the no-tool circuit breaker in `references/subagent-contracts.md` before artifact validation, summary finalization, or `.uat-remediation-stage` advancement. If it triggers, STOP without advancing `.uat-remediation-stage` and report the failed subagent role and task.

Under the no-tool invariant, treat unavailable tools as a provisioning failure, do not advance state, and do not retry the same prompt.

## Research Stage (TRANSIT-UAT-03)

If `research_path` from step 4 is non-empty, research already exists. Verify it before advancing:
```bash
bash "{LINK}/scripts/validate-uat-remediation-artifact.sh" research "{research_path}"
```
If validation fails, display the validator error and STOP without advancing state. Otherwise, skip to advancing the stage.

If `research_path` is empty, spawn Scout with these requirements:

Spawn setup:
- Follow `references/agent-spawn-protocol.md`. Issue a solo `scout` command contract for job `UAT remediation research` with `{round_dir}/R{RR}-RESEARCH.md` as the exact write allowance.
- Run the generic `scripts/agent-generator.sh scout` call, advance the contract to `dispatched`, and use its printed Agent-call parameters and `SPAWN_READY` name exactly.
- Omit team and worktree fields. Do not re-resolve or override model, effort, or turns. Stop and report contract or generator failures verbatim.

Task inputs:
- Pass the normalized issue list from steps 3-5, **ordered by failure_count descending**, so Scout investigates the relevant code areas for each issue.
- Use `round` from step 4 as `{RR}`.
- Pass `<output_path>{round_dir}/R{RR}-RESEARCH.md</output_path>` so Scout writes directly to the absolute host-repository round directory.

Skill activation:
- Before composing the Scout task description, evaluate installed skills visible in your system context. Read each skill's description and select only skills directly needed for this research task. Do not include implementation, build, or adjacent domain skills only because a later Lead or Dev stage can use them.
- Begin the Scout prompt with exactly one explicit skill outcome block:
  - For one or more installed skills preselected at orchestration time, use `<skill_activation>{For each selected skill: "Call Skill({skill-name})"}</skill_activation>`.
  - Use 

```text
<skill_no_activation>Evaluated installed skills for this task. No skills were preselected at orchestration time. Reason: {brief task-specific reason}.</skill_no_activation>
```

 when orchestration preselects none.
  - Silent omission of both blocks is invalid.
- State the skill outcome in your response before spawning the agent (for example, "Skills: activating {skill-name}" or "Skills: none preselected, {reason}").
- If the prompt or error mentions SwiftData and the research task requires SwiftData model semantics, include `swiftdata`. Do not include it only as a possible future implementation aid.
- After calling `Skill(...)`, read any specific additional files, sibling docs, or follow-up steps that the loaded skill identifies as relevant. Do not scan entire skill folders or read unrelated references.

Tools:
- Evaluate available MCP tools in your system context. If an MCP server provides documentation, search, or data retrieval capabilities relevant to the issues, note it in the Scout task context. Scout then prioritizes it over generic WebSearch or WebFetch.

If you preselected one or more skills, run `bash "{LINK}/scripts/extract-skill-follow-up-files.sh" "{all preselected skill names from the activation block}" 2>/dev/null || true` before spawning the UAT remediation research Scout. If the helper prints a `<skill_follow_up_files>` block, paste it immediately after the follow-up-read sentence in the spawned payload. Otherwise omit that block.

Render the prompt prefix from `{LINK}/references/skill-activation-payload.md` with the local `skill_calls`, task-specific `no_skill_reason`, and optional helper-emitted `follow_up_files_block`. Prepend the rendered bytes to the child prompt so the rendered skill outcome tag is its first line. Do not paste the template path, variables, or an unresolved `@` include into the child prompt.

- **Live data validation:** For any issue that involves external data sources (APIs, databases, services), include this text in the Scout prompt: *"Public/anonymous HTTP validation uses WebFetch. Authenticated/private read-only probes use verified-safe Bash helper scripts or curl wrappers after preflight. Do not run unsafe or mutating probes. Defer those to Dev/Debugger. When live validation runs or is deferred, include `## Live Validation Evidence` with `command_shape`, `exit_status`, `redacted_evidence`, `expected_shape`, `confidence`, and `limitations_or_deferred_reason`."*
- After Scout completes, verify the exact research artifact before advancing:
  - If Scout returns a no-tool/tool-provisioning failure, apply the circuit breaker above before running validation.
  ```bash
  bash "{LINK}/scripts/validate-uat-remediation-artifact.sh" research "{round_dir}/R{RR}-RESEARCH.md"
  ```
  If validation fails, display the validator error and STOP without advancing state. Do not search for an alternate RESEARCH.md.
- Then advance:
  ```bash
  bash "{LINK}/scripts/uat-remediation-state.sh" advance "$PHASE_DIR"
  ```
- Then continue to the next stage (`plan`).

## Plan Stage (TRANSIT-UAT-04)

If `plan_path` from step 4 is non-empty, the plan was already written in a previous session, do NOT re-plan. Verify it, read the existing plan, and advance directly to `execute`:
```bash
bash "{LINK}/scripts/validate-uat-remediation-artifact.sh" plan "{plan_path}"
```
If validation fails, display the validator error and STOP without advancing state. If validation succeeds, read the existing plan and advance directly to `execute`.

If `plan_path` is empty, spawn one contracted `lead` to return the remediation plan content. The main session writes the artifact.

**NO team creation (NON-NEGOTIABLE).** Do not form an agent team (do not spawn teammates). Use plain sequential subagent Agent calls, remediation planning spawns Lead directly via Agent tool.

Under the non-team invariant, omit `team_name`, `run_in_background`, `isolation`, and all worktree cwd fields.

This is NOT "Plan mode steps 1-12", remediation has its own sequential flow that does not use the standard planning pipeline.

### Prepare the Lead

- Evaluate planning skills and MCP tools, then render the prompt prefix from `references/skill-activation-payload.md`.
- Follow `references/agent-spawn-protocol.md`. Issue a solo `lead` command contract for job `UAT remediation planning` with no write allowance. Run the generic `scripts/agent-generator.sh lead` call, advance the contract to `dispatched`, and use its printed Agent-call parameters and `SPAWN_READY` name exactly.
- The Lead returns the complete remediation plan as evidence. The main session persists `{round_dir}/R{RR}-PLAN.md`, then normalizes and verifies it. Omit team and worktree fields. Do not re-resolve model, effort, or turns.
### Lead prompt

Include:
  - If `research_path` from step 4 is non-empty: `Read {research_path} for full research findings before planning.` (Lead must read the file, do NOT inline a summary.)
  - The priority-ranked issue list from step 5 with recurring-issue annotations.
  - `"Read the remediation plan template at {LINK}/templates/REMEDIATION-PLAN.md and follow its structure exactly. This template is different from the regular PLAN.md, it has no wave or depends_on fields because remediation tasks are always sequential. Produce a flat ordered task list where each task can see the results of previous tasks."` (Lead must read the template file.)
  - Canonical target filename for the returned plan: `{round_dir}/R{RR}-PLAN.md` (using `round` from step 4 as `{RR}` and the absolute `round_dir` from step 4). The Lead returns content, and the main session writes it.
- Display `◆ Spawning Lead agent...` → `✓ Lead agent complete`.
- If Lead returns a no-tool/tool-provisioning failure, apply the circuit breaker above before normalizing or validating the plan.
### Validate and advance

- Normalize plan filenames:
  ```bash
  NORM_SCRIPT="{LINK}/scripts/normalize-plan-filenames.sh"
  if [ -f "$NORM_SCRIPT" ]; then
    bash "$NORM_SCRIPT" "{round_dir}"
  fi
  ```
- Verify the exact plan artifact before advancing:
  ```bash
  bash "{LINK}/scripts/validate-uat-remediation-artifact.sh" plan "{round_dir}/R{RR}-PLAN.md"
  ```
  If validation fails, display the validator error and STOP without advancing state. Do not search for an alternate PLAN.md.
- After planning completes, advance:
  ```bash
  bash "{LINK}/scripts/uat-remediation-state.sh" advance "$PHASE_DIR"
  ```

Then continue to the next stage (`execute`). Follow the autonomy rules for user approval prompts.

## Execute Stage (TRANSIT-UAT-05)

Execute the remediation plan sequentially, one contracted implementation group per task. Do not use wave parallelism or overlap groups.

Each group is the pair or trio required by `references/agent-spawn-protocol.md`. Spawn all members together, wait for their verdict, close the group, then start the next task.

### Resolve execution

- Read a non-empty `plan_path`. Otherwise read `{round_dir}/R{RR}-PLAN.md` (using `round` and the absolute `round_dir` from step 4). Extract the task list from the plan frontmatter/body. Each task has an ID (for example `P07`, `P08`, `UAT-3`).
- Each remediation task must name its implementation role and exact files. Use a configured engineering anchor role. Do not use the removed broad `dev` role.
- Follow `references/agent-spawn-protocol.md` for each task after skill selection below. Choose pair or trio from the task's test ownership. Issue the command contract from its exact files, run the generic `scripts/agent-generator.sh`, and use only the printed Agent-call parameters.

### Skill activation

- Before composing Dev task descriptions, evaluate installed skills visible in your system context. Read each skill's description. Select the task-specific skills listed in the remediation plan, plus any build, test, documentation, or domain skills that the current task directly requires. Do not carry over broad Scout/Lead context or activate skills for unrelated future tasks.
- The Dev prompt MUST begin with exactly one explicit skill outcome block. Use `<skill_activation>{For each selected skill: "Call Skill({skill-name})"}</skill_activation>` when orchestration preselects one or more installed skills, or 

```text
<skill_no_activation>Evaluated installed skills for this task. No skills were preselected at orchestration time. Reason: {brief task-specific reason}.</skill_no_activation>
```

 when orchestration preselects none. Silent omission of both blocks is invalid.
- After evaluating, state the skill outcome in your response (for example, "Skills: activating {skill-name}" or "Skills: none preselected, {reason}") so the user sees it before you spawn the agent.
#### Follow-up context

- After calling `Skill(...)`, read the specific additional files, sibling docs, or follow-up read steps that the loaded skill's instructions reference for the active task. Read them before reasoning or acting. Do not scan entire skill folders or read unrelated references.
- If you preselected one or more skills, run `bash "{LINK}/scripts/extract-skill-follow-up-files.sh" "{all preselected skill names from the activation block}" 2>/dev/null || true` before spawning the UAT remediation Dev. If the helper prints a `<skill_follow_up_files>` block, paste it immediately after the follow-up-read sentence in the spawned payload. Otherwise omit that block.
- Render the prompt prefix from `{LINK}/references/skill-activation-payload.md` with the local `skill_calls`, task-specific `no_skill_reason`, and optional helper-emitted `follow_up_files_block`. Prepend the rendered bytes to the child prompt so the rendered skill outcome tag is its first line. Do not paste the template path, variables, or an unresolved `@` include into the child prompt.
### Execute tasks

- For each task in the plan, sequentially:
  - Verify that the task names a configured engineering role, exact implementation files, exact test files, and acceptance criteria. Stop on a broad or missing file scope.
  - Issue a pair or trio task contract from those exact files. Run the generic generator in the matching `--pair` or `--trio` mode and advance the contract to `dispatched`. Spawn every generated name together with the printed Agent-call parameters. Wait for the critic or `test-dev` verdict before continuing.
  - Prompt the implementation group with the task details and relevant codebase conventions. Generated agents change only their allowed files and return structured evidence. They do not commit or write the remediation summary.
  - The main session reviews the evidence, owns the task commit, and appends the accepted task section to `{summary_path}` using `templates/REMEDIATION-SUMMARY.md`.
  - Apply the no-tool circuit breaker before committing, writing summary state, spawning the next group, or advancing remediation state.
- **Frontmatter finalization:** After all implementation groups complete, the main session updates the YAML frontmatter in `{summary_path}`. It sets `status` to `complete` (or `partial`/`failed`) and `completed` to today's date. It sets `tasks_completed` to the actual count. It populates `commit_hashes`, `files_modified`, and `deviations` with aggregate data from all task sections. Strip any trailing blank lines from the file.
- **Summary validation:** Verify the exact summary artifact before advancing:
  ```bash
  bash "{LINK}/scripts/validate-uat-remediation-artifact.sh" summary "{summary_path}"
  ```
  If validation fails, display the validator error and STOP without advancing state. Do not search for an alternate SUMMARY.md.
- **Worktree cleanup scan:** After execution, look for orphan CC worktrees:
  ```bash
  if [ -d ".claude/worktrees" ] && [ -n "$(ls -A .claude/worktrees 2>/dev/null)" ]; then
    echo "⚠ Found CC worktrees at .claude/worktrees/, run 'git worktree list' and 'git worktree remove <path>' to clean up"
  fi
  ```
  If the scan finds worktrees, display this warning to the user. Do NOT auto-delete them.
- Advance:
  ```bash
  bash "{LINK}/scripts/uat-remediation-state.sh" advance "$PHASE_DIR"
  ```
- **Chain into re-verification (NON-NEGOTIABLE):** After the execute stage advances to `done`, the remediation round is complete but NOT verified. Immediately prepare for re-verification and chain into Verify mode in the same turn:
  - Run: `bash "{LINK}/scripts/prepare-reverification.sh" "$PHASE_DIR"`
  - **Error guard:** On a script failure (non-zero exit), display the error message and **STOP**. Do not attempt to enter Verify mode with stale/missing context.
  - Parse output: `archived=kept|in-round-dir|<original-uat-basename>`, `skipped=already_archived|ready_for_verify|cap_reached`, `round_file=...`, `phase=NN`, `layout=...`
  - If `skipped=cap_reached`, display the same UAT remediation cap banner as the top-level re-verification flow and STOP. Use `max_rounds={N}` from the script output.
  - If `archived=kept`, display "Phase UAT preserved. Starting re-verification in round dir."
    If `skipped=ready_for_verify`, display "Round {NN} remediation complete. Starting re-verification."
    If `skipped=already_archived`, display "UAT already archived. Starting re-verification."
    Otherwise, display "Archived previous UAT → {round_file}. Starting re-verification."
  - Planning artifact boundary commit (conditional):
    ```bash
    PG_SCRIPT="{LINK}/scripts/planning-git.sh"
    if [ -f "$PG_SCRIPT" ]; then
      bash "$PG_SCRIPT" commit-boundary "execute phase {NN} remediation round {RR}" .meridian/config.json
    else
      echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
    fi
    ```
  - **Continue directly into Verify mode** for this phase, do NOT stop, do NOT tell the user to run `/meridian:transit`. Enter Verify mode (below) inline in the same turn. The pre-computed verify context can be stale (the command's pre-computed context block built it at command load, before remediation). Re-compute it:
    ```bash
    bash "{LINK}/scripts/compile-verify-context-for-uat.sh" "$PHASE_DIR"
    ```
    **uat_path validation (defense-in-depth):** After parsing the fresh verify context, verify that `uat_path` already points at the current remediation round's round-scoped UAT path. That path is `remediation/uat/round-{RR}/R{RR}-UAT.md` for round-dir layout and `remediation/round-{RR}/R{RR}-UAT.md` for legacy layout. If it does not (for example, it points to the phase-root UAT like `03-UAT.md`), override it. Use the round-scoped path for the current round from `uat-remediation-state.sh`. This override keeps re-verification from overwriting the original phase-root UAT.
    Use this fresh verify context for the Verify mode UAT prompt loop.
  Do NOT present the remediation summary and stop. The summary serves only a session that cannot continue (for example, after compaction).

## Fix Stage (TRANSIT-UAT-06)

Route to a quick-fix implementation path for the same phase using the normalized issue list from step 3. Follow `references/agent-spawn-protocol.md` with an exact pair or trio contract. Generated agents return evidence, and the main session owns the commit. After accepted changes, advance:

Apply the no-tool circuit breaker in `references/subagent-contracts.md` to the quick-fix Dev return before the advance below. If it triggers, STOP without advancing `.uat-remediation-stage`, report the failed Dev quick-fix task, and do not enter re-verification.

Under the no-tool invariant, treat unavailable tools as a provisioning failure, do not advance state, and do not retry the same prompt.

```bash
bash "{LINK}/scripts/uat-remediation-state.sh" advance "$PHASE_DIR"
```

Then chain into re-verification using the same steps as the execute stage above (prepare-reverification → commit boundary → Verify mode inline). Do NOT suggest `/meridian:transit`, enter Verify mode in the same turn.

## Fallback Remediation Summary (TRANSIT-UAT-07)

Present a remediation summary only after re-verification chaining fails to complete in this turn. Context window limits (compaction among them) and session interruption both cause that. The summary contains phase, issue count, severity mix, current stage, chosen path (`research -> plan -> execute` or quick-fix), and per-test recurrence. For any issue with `failure_count >= 2`, include: `"⚠ RECURRING ({failure_count}/{round} rounds): {ID}, {DESCRIPTION}"`. First-time failures display without the annotation. End with: "Run `/meridian:transit` to start re-verification."

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/compile-verify-context-for-uat.sh`
- `scripts/extract-skill-follow-up-files.sh`
- `scripts/normalize-plan-filenames.sh`
- `scripts/planning-git.sh`
- `scripts/prepare-reverification.sh`
- `scripts/uat-remediation-state.sh`
- `scripts/validate-uat-remediation-artifact.sh`
