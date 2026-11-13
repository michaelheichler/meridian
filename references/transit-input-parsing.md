# Meridian Transit Input Parsing

## Initialization routing before gates

When `planning_dir_exists=false`, validate detector output, then resolve import intent before any index or workflow gate. Explicit `--import [path]` enters Import mode. Confirm clear natural-language import intent first. If the detector finds an external plan source without explicit intent, offer `Import external plan`, `Start fresh initialization`, and `Cancel` as Mode Import documents. Without an import selection, enter Init Redirect and stop. Other flags do not override the missing planning directory. Do not run full parsing, state repair, or either gate on this path.

For initialized projects, run the index freshness gate before full parsing and other lifecycle routes. After an import promotes a planning directory, re-run detection and apply that gate before choosing the next lifecycle mode.

## Main-session Decision Handoffs

Only the main session can call `AskUserQuestion`.
Before each `AskUserQuestion` call, the main session follows
`references/meridian-brand-essentials.md`. A worker that reaches a decision
boundary returns the `user_decision_required` JSON from
`references/subagent-contracts.md`. The worker does not mutate state or claim a
todo until the main session responds. It also does not start the next stage
before that response. A declined choice keeps the state and reports the
documented Next Up command.

## Generated Agent Authority

For every agent spawn, follow `references/agent-spawn-protocol.md`. The main
session issues the command contract, runs `scripts/agent-generator.sh`, and
uses its `SPAWN_READY` name and printed Agent-call parameters exactly. Generated output is
the sole authority for name, model, effort, and turn limit. Do not select them
from a static model profile. Every spawn below uses the generic contract-issuing
generator protocol.


Loaded via `@${CLAUDE_PLUGIN_ROOT}/references/transit-input-parsing.md` from `commands/transit.md` to resolve `/meridian:transit` arguments and state-driven routing.

## Pre-Parsing and Todo Resolution (TRANSIT-IP-01)

Initialize the working input from the user input above in the invoking command. Apply todo resolution and ref cleanup to that working copy, not to the original user input block.

**Pre-parse (todo number resolution)**: If the working input is a bare integer (matches `^[0-9]+$` with no other text or flags), inspect the persisted session snapshot from the latest `/meridian:list-todos` invocation. Do this before you decide whether this integer is a todo or a phase target:
```bash
bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/todo-lifecycle.sh" snapshot-show
```
- If the snapshot is present and `filter=null`, resolve the integer as a todo selection via:
  ```bash
  bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/resolve-todo-item.sh" <N> --session-snapshot --require-unfiltered --validate-live
  ```
  If `status` is `"ok"`, preserve `TODO_SELECTED=true` and store the full payload as `TODO_SELECTED_JSON`. Then replace the working input with the item's `command_text` and keep the resolved `ref`/`state_path` metadata for later pickup. If the resolved `state_path` points under `.meridian/milestones/`, STOP with the message `This todo came from archived milestone state. Restore the writable root STATE.md first by restarting so session-start.sh can run migration, or run 'bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/migrate-orphaned-state.sh .meridian'.`. Do not continue using the archived description as live work input.
- If the snapshot is present and `filter` is non-null, do **not** treat the integer as a claimable backlog todo. Preserve the existing bare phase-number path instead. If the integer later fails to resolve as a valid phase target, fail closed with: 

```text
Current list view is filtered, rerun unfiltered /meridian:list-todos before using /meridian:transit N as a todo pickup.
```


- If the snapshot is missing or malformed, preserve the existing bare phase-number path. Do **not** silently fall back to live unfiltered backlog resolution for todo pickup.

If `TODO_SELECTED_JSON` exists and its `ref` is non-null, eagerly load detail during Input Parsing, before routing commits to the todo-derived request:
```bash
bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/todo-details.sh" get {hash}
```
If `status` is `"ok"`, store `DETAIL_STATUS=ok`, `detail.context`, and `detail.files` for later use. If `status` is `"not_found"` or `"error"`, record the matching `DETAIL_STATUS` value and run:
```bash
bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/todo-lifecycle.sh" detail-warning {hash}
```
Continue without detail.

**Pre-parse (ref tag extraction)**: Before you evaluate the paths below, look for a `(ref:HASH)` suffix (8 hex characters) at the end of the working input. If you find one, extract the hash and strip the ref tag (including any leading space) from the working input. All later parsing uses the cleaned arguments. The ref must not interfere with flag detection or keyword routing. It must not interfere with mode selection either. Store the extracted hash for later use. If `TODO_SELECTED_JSON` already exists from the numbered-todo path above, reuse its resolved ref/detail metadata and do not reload detail here. For non-todo manual `(ref:HASH)` inputs, defer detail loading until a mode that acts on the todo needs it. If you find no ref tag, there is no hash to store.

**Todo pickup boundary (non-negotiable)**: Claim a numbered todo selected through `TODO_SELECTED_JSON` only after routing commits to the todo-derived request. Any AskUserQuestion confirmation gate must also complete successfully first. If routing falls back to a phase-number path, stops on a guard, or the user declines confirmation, leave the todo untouched. Manual text and manual `(ref:HASH)` inputs never trigger pickup.

When the chosen route does commit to the todo-derived request, claim it exactly once before entering the chosen mode body by piping `TODO_SELECTED_JSON` into:
```bash
bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/todo-lifecycle.sh" pickup /meridian:transit {DETAIL_STATUS} {cleanup_policy}
```
When `DETAIL_STATUS=ok`, set `{cleanup_policy}` to `safe`. Otherwise set it to `keep`. If the helper returns `status="error"`, STOP with its `message` value. If it returns `status="partial"`, continue but surface the helper's `warning` value so cleanup state stays explicit.

Three input paths, evaluated in order:

## Path 1. Flag Detection (TRANSIT-IP-02)

Look for flags in the working input. If any mode flag is present, go directly to that mode.

Lifecycle modes:
- `--plan [N]` -> Plan mode
- `--execute [N]` -> Execute mode
- `--discuss [N]` -> Discuss mode
- `--assumptions [N]` -> Assumptions mode
- `--verify [N]` -> Verify mode
- `--archive` -> Archive mode

Phase setup and mutation modes:
- `--scope` -> Scope mode
- `--add "desc"` -> Add Phase mode
- `--insert N "desc"` -> Insert Phase mode
- `--remove N` -> Remove Phase mode

Behavior modifiers (combinable with mode flags):
- `--effort <level>`: thorough|balanced|fast|turbo (overrides config)
- `--skip-qa`: skip post-build QA
- `--skip-audit`: skip non-UAT pre-archive audit checks (hard UAT gate still enforced)
- `--yolo`: skip all confirmation gates, auto-loop remaining phases
- `--plan=NN`: execute single plan (bypasses wave grouping)
- A bare integer `N` targets phase N (works with any mode flag)

If flags are present, skip the confirmation gate (flags express explicit intent).

## Path 2. Natural Language Intent (TRANSIT-IP-03)

If the working input is present but no flags detected, interpret user intent:
- Explicit external plan import or migration keywords (import this plan, migrate .planning, bring in external plans) -> Import mode
- Discussion keywords (talk, discuss, explore, think about, what about) -> Discuss mode
- Assumption keywords (assume, assuming, what if, what are you assuming) -> Assumptions mode
- Planning keywords (plan, scope, break down, decompose, structure) -> Plan mode
- Execution keywords (build, execute, run, do it, go, make it, ship it) -> Execute mode
- Verification keywords (verify, test, uat, check my work, acceptance test, walk through) -> Verify mode
- Phase mutation keywords (add, insert, remove, skip, drop, new phase) -> relevant Phase Mutation mode
- Completion keywords (done, ship, archive, wrap up, finish, complete) -> Archive mode

If the intent is ambiguous, call AskUserQuestion with contextual options.

Confirm the interpreted intent with AskUserQuestion before executing.

Explicit `--import [path]` routes to Import mode before state detection. Clear natural-language import intent also routes before the uninitialized-project redirect after confirmation. Existing remediation and lifecycle state routes retain their priority when import intent is absent.

## Path 3. State Detection (TRANSIT-IP-04)

If the working input is empty, evaluate phase-detect.sh output. First match determines mode:

**Phase-detect error guard (NON-NEGOTIABLE)**: If the output contains `phase_detect_error=true`, display:
"⚠ Phase detection failed. Run `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/phase-detect.sh` manually to debug."
STOP. Do NOT manually scan for project state or improvise routing, because incorrect routing can corrupt archived milestones.

**Misnamed plan auto-repair**: If the output contains `misnamed_plans=true`, normalize all phase directories before routing:
```bash
NORM_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/normalize-plan-filenames.sh"
if [ -f "$NORM_SCRIPT" ]; then
  for pdir in .meridian/phases/*/; do
    [ -d "$pdir" ] && bash "$NORM_SCRIPT" "$pdir"
  done
fi
```
Display: "⚠ Renamed misnamed plan files to `{NN}-PLAN.md` convention."
Then re-run phase-detect.sh and use updated output for routing below.

**State-driven routing prohibition (NON-NEGOTIABLE)**: When state detection routes to a mode, call its confirmation gate (AskUserQuestion, see Confirmation Gate section below) in the same turn. Execute the mode inline after the user responds. Do NOT use TaskCreate, TaskUpdate, or any task management tool for state-driven routing. Those tools add overhead and delay execution. State routing is deterministic. The pre-computed data in the Context section provides all routing information. Do not spawn tasks or read protocol files for routing decisions. After confirmation (when required by the routing table), execute the mode inline. Modes that spawn agents (Scout, Lead, Dev) do so within their step-by-step flow. This delegates work units within a stage, not the stage pipeline itself.

<examples>
<example type="anti-pattern" label="WRONG, delegating the stage pipeline via TaskCreate">
State detects needs_uat_remediation → TaskCreate("Research"), TaskCreate("Plan"), TaskCreate("Execute") with blocking dependencies. The stages run as separate delegated tasks, breaking state management and losing orchestrator control between stages.
</example>
<example type="correct" label="RIGHT, inline orchestration with agent spawning per stage">
State detects needs_uat_remediation and enters the mode inline. Step 4 displays the main-session progress list (Research, Plan, Execute). Step 6 spawns Scout for research, advances state, spawns Lead for planning, advances again, spawns Dev for execution, and chains into re-verification.
</example>
</examples>

| Priority | Condition | Mode | Confirmation |
| --- | --- | --- | --- |
| 0.5 | explicit or confirmed import intent | Import | No confirmation for an explicit flag. For natural language, confirm Import mode before execution. |
| 1 | `planning_dir_exists=false` and no import intent | Init redirect | (redirect, no confirmation) |
| 2 | `project_exists=false` | Bootstrap | → AskUserQuestion: "No project defined. Set one up?" |
| 3 | `next_phase_state=needs_uat_remediation` | UAT Remediation | If auto_uat=true, no confirmation. If auto_uat=false: → AskUserQuestion: "Phase {NN} has unresolved UAT issues. Continue with remediation now?" |
| 3.5 | `next_phase_state=needs_qa_remediation` | QA Remediation | If auto_uat=true, no confirmation. If auto_uat=false: → AskUserQuestion: "Phase {NN} has QA failures. Continue with QA remediation?" |
| 4 | `next_phase_state=needs_reverification` | Re-verify | If auto_uat=true, no confirmation. If auto_uat=false: → AskUserQuestion: "Phase {NN} remediation complete. Run re-verification?" |
| 5 | `milestone_uat_issues=true` | Milestone UAT Recovery | (mode handles confirmation, see Milestone UAT Recovery steps) |
| 6 | `phase_count=0` | Scope | → AskUserQuestion: "Project defined but no phases. Scope the work?" |
| 7 | `next_phase_state=needs_verification` | Verify | (no confirmation, auto_uat intent or active UAT resume). **QA gate**: If `qa_after_uat_dormant=true` or `qa_reason=uat_cutover`, skip QA and stay in the UAT lane. If neither applies and `qa_status=pending`, map `qa_reason` through the reason labels below. Then display "Phase {NN} QA is pending ({reason label}), running QA now." and spawn QA inline first. This state also covers three other cases. The first is an `all_done` milestone retargeted to this state because authoritative pre-UAT QA on a completed no-UAT phase is stale/missing. The second is a fully built no-UAT phase retargeted back into verification while QA is still pending, even with `auto_uat=false`. The third is an active current-round UAT artifact that must resume Verify instead of entering Re-verify preparation. If `qa_status=failed`, enter QA remediation inline only before UAT cutover. Do not proceed to Verify mode unless `qa_status` is `passed`, `remediated`, or explicitly dormant after UAT cutover. |
| 8 | `next_phase_state=needs_discussion` | Discuss | → AskUserQuestion: "Phase {NN} needs discussion before planning. Start discussion?" |
| 9 | `next_phase_state=needs_plan_and_execute` | Plan + Execute | → AskUserQuestion: "Phase {NN} needs planning and execution. Start?" |
| 10 | `next_phase_state=needs_execute` | Execute | → AskUserQuestion: "Phase {NN} is planned. Execute it?" |
| 11 | `next_phase_state=all_done` | Archive | → AskUserQuestion: "All phases complete. Run audit and archive?" (not while a `first_qa_attention_phase` remains) |

**all_done QA-attention fallback (pending)**: When `next_phase_state=all_done`, `first_qa_attention_phase` is non-empty, and `qa_attention_status=pending`, do **not** archive yet. Target `first_qa_attention_phase` / `first_qa_attention_slug` and continue into Verify mode instead. This is the stage-less resume path for a completed pre-UAT phase whose QA verification is still missing or stale. It applies even with `auto_uat=false`. If that phase has any UAT state or artifact, QA attention is dormant and this fallback must not run.

**Earlier-work QA-attention fallback (failed)**: The earlier-work states are `needs_discussion`, `needs_plan_and_execute`, and `needs_execute`. When `next_phase_state` is still an earlier-work state, but `first_qa_attention_phase` is non-empty and `qa_attention_status=failed`, do **not** continue into that unrelated earlier work. Target `first_qa_attention_phase` / `first_qa_attention_slug` and continue into the existing QA Remediation mode instead. This is the stage-less resume path for a completed pre-UAT phase with phase-level QA findings and a persisted known-issues backlog. No `.qa-remediation-stage` exists for that phase yet. If that phase has any UAT state or artifact, treat the QA metadata as dormant and do not enter QA Remediation.

**QA remediation resume priority (needs_qa_remediation), IMMEDIATE RESUME (NON-NEGOTIABLE):**
Persisted QA remediation / known-issues backlog is the authoritative plain `/meridian:transit` resume target. When `next_phase_state=needs_qa_remediation`, close the QA backlog first. Do **not** skip ahead to unrelated earlier work (discussion, planning, execution). The only exception is an active UAT remediation path that already has higher priority.

**Re-verify after remediation (needs_reverification), IMMEDIATE EXECUTION (NON-NEGOTIABLE)**:
When `next_phase_state=needs_reverification`, execute these steps inline in the same turn. Do NOT create tasks, read protocol files, or perform any intermediate planning:
1. Run: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/prepare-reverification.sh {phase-dir}`
2. **Error guard**: If the script fails (non-zero exit), display the error message and **STOP**. Do not attempt to enter Verify mode with stale/missing context.
3. Parse output: `archived=kept|in-round-dir|<original-uat-basename>`, `skipped=already_archived|ready_for_verify|cap_reached`, `round_file=...`, `phase=NN`, `layout=...`
  If `skipped=cap_reached`, display the UAT remediation cap banner and STOP. Use `max_rounds={N}` from the script output:
  ```text
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    Reached maximum UAT remediation rounds ({N}).
    Review issues manually or adjust max_uat_remediation_rounds
    in config.json.
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ```
  Do NOT refresh verify context or enter Verify mode.
4. If `archived=kept`, display "Phase UAT preserved. Starting fresh re-verification in round dir."
   If `archived=in-round-dir`, display "Archived previous UAT → {round_file}. Starting fresh re-verification."
   If `skipped=already_archived`, display "UAT already archived. Starting fresh re-verification."
   If `skipped=ready_for_verify`, display "Round {NN} remediation complete. Starting fresh re-verification."
   If no earlier case matches and `archived=` is the original phase-root UAT basename (flat/legacy layout), display "Archived previous UAT → {round_file}. Starting fresh re-verification."
5. Refresh verify context and UAT resume metadata for that phase:
  ```bash
  bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-verify-context-for-uat.sh "{phase-dir}"
  bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/extract-uat-resume.sh "{phase-dir}"
  ```
  Use this refreshed output in place of the pre-computed verify blocks from Context.
  **uat_path validation (defense-in-depth)**: The current remediation round has a round-scoped UAT path. It is `remediation/uat/round-{RR}/R{RR}-UAT.md` for round-dir layout and `remediation/round-{RR}/R{RR}-UAT.md` for legacy layout. If the refreshed `uat_path` does not already point at that path, run:
  ```bash
  bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/uat-remediation-state.sh get-or-init "{phase-dir}" major
  ```
  Parse `round=RR` and `layout=...`, then override `uat_path` with the matching round-scoped path for that layout before entering Verify mode.
6. **Continue directly into Verify mode below** for that phase, do NOT stop, do NOT tell the user to run a separate command.

The `needs_reverification` state fires regardless of `auto_uat`, because remediation always requires re-verification. The `auto_uat` flag only controls whether the main session prompts the user for confirmation.

**auto_uat verification / active UAT resume (needs_verification)**: When `next_phase_state=needs_verification`, **continue directly into Verify mode below** and target phase `{next_phase}` (from phase-detect output). Do NOT stop and tell the user to run a separate command. Verify mode runs the CHECKPOINT loop **inline in this conversation** via AskUserQuestion. Do NOT spawn a QA agent or any subagent for UAT (see Verify mode's inline execution rule). When `auto_uat=true` and a completed phase has no UAT verification yet, this state fires. It fires regardless of whether later phases still need work. When phase-detect reports an active current-round UAT blocker (`uat_blocking_status=active`), this state also fires. In that case, resume the existing UAT so Re-verify preparation does not archive the in-progress human test state. After verification completes, the next `/meridian:transit` call re-runs phase-detect and routes to the next pending phase.

**QA gate before UAT (needs_verification), NON-NEGOTIABLE:**
Before entering Verify mode (UAT), check `qa_status` from phase-detect output:
- If `qa_after_uat_dormant=true` or `qa_reason=uat_cutover`, proceed to Verify mode (UAT) without running QA. QA remediation is a pre-UAT route only. Once any UAT state or artifact exists for the target phase, stale QA remediation metadata for that phase is traceability-only. That metadata must not send `/meridian:transit` back into QA Remediation.
- If `qa_status=passed` or `qa_status=remediated`, proceed to Verify mode (UAT). These values mean VERIFICATION.md exists with PASS and the product code has not changed since QA verified it (staleness check via `verified_at_commit`).
- `qa_status=pending` (no VERIFICATION.md, malformed/untrusted VERIFICATION.md, deterministic gate rerun, or stale PASS): display "Phase {NN} QA is pending ({reason label}), running QA now." and spawn QA inline first. Resolve `{reason label}` from `qa_reason`. If `qa_reason=none` or is empty, use `qa_attention_reason`. If both are empty/none, omit the parenthetical.

  **QA pending artifact and gate reason labels:**
  - `missing_verification_artifact` → `no verification artifact exists`
  - `verification_result_missing` → `verification result is missing`
  - `verification_result_unrecognized` → 

```text
verification result is unrecognized
```


  - `qa_gate_rerun_required` → `the QA gate requires a rerun`
  - `qa_gate_output_missing` → `the QA gate did not return a routing decision`

  **Repository freshness reason labels:**
  - `working_tree_changed` → `the working tree changed after QA`
  - `git_status_failed` → `git status failed during freshness check`
  - `git_log_failed` → `git log failed during freshness check`
  - `product_commit_unavailable` → 

```text
no product-code commit could be resolved
```



  **Product freshness reason labels:**
  - `verified_at_commit_mismatch` → `product code changed since QA`
  - `product_changed_after_verification` → `product code changed after QA`
  - `freshness_baseline_unavailable` → 

```text
QA freshness could not be proven
```


  - Unknown non-empty token → use the token verbatim.

  Then continue with QA:
  - If the phase-level verification artifact does not yet exist, backfill tracked known issues from completed summaries before QA starts:
    ```bash
    bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/track-known-issues.sh" sync-summaries "{phase-dir}" 2>/dev/null || true
    ```
    This backfill is only for the first phase-level QA run after execution. Do not reuse it for round-scoped remediation verification or generic stale-verification reruns.
  ```bash
  bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/track-known-issues.sh" sync-verification "{phase-dir}" "{QA-output-path}" 2>/dev/null || true
  ```
  After sync-verification, auto-promote surviving known issues to `STATE.md ## Todos`:
  ```bash
  bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/track-known-issues.sh" promote-todos "{phase-dir}" 2>/dev/null || true
  ```
  Then run the deterministic gate:
  ```bash
  bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-result-gate.sh" "{phase-dir}"
  ```
  **Follow `qa_gate_routing` output exactly, with no exceptions, no judgment, no rationalization. Do NOT evaluate whether a failure looks justified or acceptable. Do NOT treat a failure as minor. The gate script already made the decision:**
  - `qa_gate_routing=PROCEED_TO_UAT` → proceed to Verify mode (UAT)
  - `qa_gate_routing=REMEDIATION_REQUIRED` → init QA remediation: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-remediation-state.sh init {phase-dir}`, then enter QA Remediation mode below. If `qa_gate_known_issues_override=true`, the contract verification passed but `{qa_gate_known_issue_count}` unresolved tracked known issues remain in `{phase-dir}/known-issues.json`.
  - `qa_gate_routing=QA_RERUN_REQUIRED` → re-spawn QA agent immediately (max 2 retries).
    - If `qa_gate_deviation_override=true`, tell QA: "Previous QA run found PASS but SUMMARY.md files contain {qa_gate_deviation_count} deviations that were not reflected as FAIL checks. Each deviation MUST become a FAIL check, do not rationalize deviations as acceptable."
    - If `qa_gate_plan_coverage` is present, tell QA: "Previous QA run only verified {qa_gate_plans_verified_count}/{qa_gate_plan_count} plans. Every plan in the phase must be verified, include all plan IDs in plans_verified."
    - If QA fails to produce a valid result after 2 re-runs, STOP and escalate to user: "QA failed to produce a valid VERIFICATION.md after {N} attempts. Manual intervention needed."
- `qa_status=failed` (VERIFICATION.md exists with FAIL/PARTIAL): init QA remediation and enter QA Remediation mode
- `qa_status=remediating`: does not reach here (phase-detect routes to `needs_qa_remediation` first)
- The `--skip-qa` flag bypasses contract-QA execution, but it does **not** bypass unresolved phase known issues. UAT still cannot proceed while `{phase-dir}/known-issues.json` contains tracked issues.

**QA Remediation mode (needs_qa_remediation), cross-session recovery**:
When `next_phase_state=needs_qa_remediation`, resume QA remediation at the persisted stage. This is the cross-session recovery path. The inline execution path is in execute-protocol.md Step 4. This state also covers a completed phase with no UAT yet, where a phase-level QA PASS artifact already exists. Unresolved tracked known issues in that phase still force remediation before UAT can begin.

**Execution model:** This mode runs inline, the orchestrator manages stage transitions and spawns agents for the actual work within each stage. Do not decompose the stages into TaskCreate items, they are sequential steps of this conversation, not delegated tasks.

1. Read current state: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-remediation-state.sh get-or-init {phase-dir}`
  Parse output: `stage`, `round`, `round_dir`, `source_verification_path`, `source_fail_count`, `known_issues_path`, `known_issues_count`, `input_mode`, `verification_path`.
   If remediation state was absent, `get-or-init` initializes round 01 before stage-specific routing. This is the deterministic stage-less resume path for a persisted known-issues backlog.
  <qa_remediation_artifact_contract>
  `round_dir`, `source_verification_path`, `known_issues_path`, and `verification_path` are authoritative host-repository paths from `qa-remediation-state.sh` metadata. Claude Code can run subagents from `.claude/worktrees/agent-*` sidechain CWDs. Pass these exact paths to Lead, Dev, and QA prompts and never rewrite them relative to the current CWD. Rewriting them relative to sidechain CWDs can write or read remediation artifacts from the wrong location and break resume or verification.
  </qa_remediation_artifact_contract>
  <qa_remediation_spawn_contract>
  QA remediation spawns are plain sequential subagent calls. Do not form an agent team (do not spawn teammates). Use plain sequential subagent Agent calls.

  - **Non-team invariant**: Omit `team_name`, `run_in_background`, `isolation`, and all worktree cwd fields.

Use the remediation metadata paths above instead of forcing Claude worktree isolation or spawn cwd handoffs.
  </qa_remediation_spawn_contract>
  <qa_remediation_no_tool_circuit_breaker>
  After any QA remediation Lead, Dev, or QA subagent returns, follow the no-tool circuit breaker in `references/subagent-contracts.md`. Apply it before artifact validation and deterministic gates, and before state advancement. If it triggers (unavailable tools are a provisioning failure), STOP without advancing `.qa-remediation-stage` or retrying the same prompt. Report the failed role and stage or task.
  </qa_remediation_no_tool_circuit_breaker>
2. Read remediation inputs.
- Round 01 reads the phase-level VERIFICATION (`{NN}-VERIFICATION.md` or brownfield `VERIFICATION.md`)
- Round 02+ reads the previous round's `R{RR}-VERIFICATION.md`
- If `known_issues_count>0`, read `known_issues_path` as the authoritative unresolved known-issues backlog for this phase.
- `input_mode=verification` → remediate FAIL rows only
- `input_mode=known-issues` → remediate tracked known issues only
- `input_mode=both` → remediate both FAIL rows and tracked known issues in the same round

**Stage-specific actions:**

#### stage=plan

Create `R{RR}-PLAN.md` in `{round_dir}`.

**Inputs and classifications**:
- When `source_fail_count>0`, read the `source_verification_path` failed checks. These are the current contract issues to fix
  - When `known_issues_count>0`, read `known_issues_path`. These tracked phase issues must clear before UAT can proceed
    - Round 01 uses the phase-level VERIFICATION (`{NN}-VERIFICATION.md` or brownfield `VERIFICATION.md`).
    - Round 02+ first checks the previous round's `R{RR}-VERIFICATION.md`. If that artifact still contains FAIL checks, use it. If it passed QA but the deterministic gate still required another remediation round, carry forward an earlier artifact. Use the nearest earlier verification artifact in the remediation chain that still contains the unresolved FAILs.
    - If `source_verification_path` is empty and `known_issues_count=0`, STOP and, before planning, restore the earlier verification artifact meant to carry the unresolved FAILs. When the carried-forward phase-level source artifact is missing and there is no known-issues backlog to remediate, do NOT silently continue.

**Deviation Classification (NON-NEGOTIABLE):** For each FAIL check in the source VERIFICATION.md, classify as exactly one of:
    **Implementation fixes:**
    - **`code-fix`**: The code/config must change to match the plan. The remediation plan MUST include tasks that modify the executable/config/test artifacts that actually implement the fix, not just planning or documentation files.

    **Plan and process decisions:**
    - **`plan-amendment`**: The deviation was a valid improvement over the original plan. The remediation plan MUST include a task to update the original PLAN.md with the actual approach and rationale, marking the deviation as resolved-by-amendment.
    - **`process-exception`**: Genuinely non-fixable retroactive issue (for example, cannot un-batch a historical commit without risky rebase). The remediation plan must include the exception classification with explicit reasoning why it is non-fixable.

    **Documentation fixes:**
    - **`doc-fix`**: The documentation artifact is the product surface under test. Include `path: "docs/file.md"` for the named documentation path, and record that same path in the round summary.
  - If ANY FAIL check is classifiable as `code-fix`, `doc-fix`, or `plan-amendment`, **the plan MUST include at least one such task**. When code-fix, doc-fix, or plan-amendment alternatives exist, a plan that classifies all FAIL checks as `process-exception` is itself a defect. Documentation-only changes to SUMMARY.md deviations arrays are NOT a valid resolution for code/architecture deviations.
  - Include `fail_classifications:` YAML array in R{RR}-PLAN.md frontmatter.
    - `code-fix` / `process-exception` entries: `{id: "FAIL-ID", type: "code-fix|process-exception", rationale: "..."}`
    - `doc-fix` entries: `{id: "FAIL-ID", type: "doc-fix", path: "docs/file.md", rationale: "..."}`
    - `plan-amendment` entries MUST also identify the original plan that the round amends: `{id: "FAIL-ID", type: "plan-amendment", rationale: "...", source_plan: "01-01-PLAN.md"}`. `source_plan` must reference an original plan in the current phase only, never a sibling phase, archived milestone, or remediation plan.

**Known-issue contract**:
- Always include `known_issues_input:` and `known_issue_resolutions:` in R{RR}-PLAN.md frontmatter. When `known_issues_count=0` or `input_mode=verification`, set both to empty arrays (`known_issues_input: []` and `known_issue_resolutions: []`) rather than omitting them.
  - When `input_mode=known-issues` or `input_mode=both`, populate `known_issues_input:` with every carried known issue from `known_issues_path`. Use the canonical `{test,file,error}` JSON object-string shape that tracked issues already use.
  - When `input_mode=known-issues` or `input_mode=both`, populate `known_issue_resolutions:` with a matching entry for every carried known issue. Each entry is a `{test,file,error,disposition,rationale}` JSON object string. Valid `disposition` values are `resolved`, `accepted-process-exception`, and `unresolved`.
    - `resolved` = this round fixes the issue and QA no longer returns it in `pre_existing_issues`
    - `accepted-process-exception` = QA must verify the issue is real but non-blocking for this phase. QA must also omit it from `pre_existing_issues` and leave it visible via the summary/STATE backlog instead of reopening the round forever
    - `unresolved` = the issue remains blocking and the next round must continue to carry it
  - Do NOT omit the `known_issues_input` or `known_issue_resolutions` keys. Do NOT omit a carried known issue from either array. The deterministic gate treats missing coverage as a failed remediation round, and a QA `PASS` does not change that.

**Plan recovery and Lead spawn**:
- Scope the plan to those failures (what to fix, which files, acceptance criteria)
- Before probing for an existing plan, run the normalizer on `{round_dir}`:
    ```bash
    NORM_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/normalize-plan-filenames.sh"
    if [ -f "$NORM_SCRIPT" ]; then
      bash "$NORM_SCRIPT" "{round_dir}"
    fi
    ```
    If the canonical `{round_dir}/R{RR}-PLAN.md` exists after normalization, run the validator command from the validation step below on that exact artifact. If validation fails, display the validator error and STOP without advancing `.qa-remediation-stage`. If validation passes, do not spawn Lead again. Reuse the persisted plan and continue at the final post-validation state-advance step below. This preserves a valid plan written before an interrupted `stage=plan` resume instead of overwriting it.

**Generate a missing plan**

- The main session coordinates the remediation loop and spawns exactly one generated `lead` to write `{round_dir}/R{RR}-PLAN.md`.
  - Follow `references/agent-spawn-protocol.md`. Issue a solo read-only `lead` command contract for job `R{RR} remediation planning` with no write allowance. Run the generic `scripts/agent-generator.sh` and advance the contract to `dispatched`. Then use the printed Agent-call parameters and `SPAWN_READY` name without re-resolving model, effort, or turns.
  - Use the generated name for both `subagent_type` and `name`. Omit team and worktree fields for this solo spawn. The Lead returns complete plan content. The main session writes the canonical plan before normalization and validation.
  - Lead prompt MUST include the authoritative `round_dir`, `source_verification_path`, `known_issues_path`, and output path `{round_dir}/R{RR}-PLAN.md`. The failed-check and known-issue inputs above. The deviation-classification and known-issue-resolution requirements above. And `Read the remediation plan template at /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/templates/REMEDIATION-PLAN.md and follow its structure exactly.`
  - After Lead returns, apply the no-tool circuit breaker in `references/subagent-contracts.md` before normalization, plan validation, or state advancement. If it triggers (unavailable tools are a provisioning failure), STOP without advancing `.qa-remediation-stage` or retrying the same prompt.
  - Normalize plan filenames before validation:
    ```bash
    NORM_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/normalize-plan-filenames.sh"
    if [ -f "$NORM_SCRIPT" ]; then
      bash "$NORM_SCRIPT" "{round_dir}"
    fi
    ```
  - Run the validator on the exact QA remediation plan artifact before advancing:
    ```bash
    bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/validate-uat-remediation-artifact.sh plan "{round_dir}/R{RR}-PLAN.md"
    ```
    If validation fails, display the validator error and STOP without advancing `.qa-remediation-stage`. Do not search for an alternate PLAN.md.
  - After plan validation passes, advance state: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-remediation-state.sh advance {phase-dir}`

#### stage=execute

Execute each `R{RR}-PLAN.md` task sequentially through `references/agent-spawn-protocol.md`.

- Require each task to name a configured engineering anchor role, exact implementation files, exact test files, and acceptance criteria. Stop on missing or broad scope.
- Issue a pair or trio PLAN task contract from those exact files. Run the generic generator in matching `--pair` or `--trio` mode and advance the contract to `dispatched`. Then spawn every generated member together with its printed Agent-call parameters.
- Generated agents modify only contracted files and return structured evidence. They do not commit or persist remediation summaries.
- The main session applies the no-tool circuit breaker. If it triggers (unavailable tools are a provisioning failure), do not commit, advance state, or retry the same prompt. Otherwise the main session reviews the critic or `test-dev` verdict. It then commits accepted output and appends the task evidence to `R{RR}-SUMMARY.md` with `templates/REMEDIATION-SUMMARY.md`.
- The summary frontmatter must aggregate `commit_hashes`, `files_modified`, and `deviations`. For known-issue input, include one `known_issue_outcomes` entry per carried issue.
  - After Dev completes without a no-tool provisioning failure, advance state: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-remediation-state.sh advance {phase-dir}`

#### stage=verify

Re-run QA.

**QA contract and artifact handling**:
- Run `compile-verify-context.sh --remediation-only {phase-dir}`. If it reports unavailable context, stop.
- Follow `references/agent-spawn-protocol.md`. Issue a solo read-only `qa` command contract with no write allowance. Run the generic `scripts/agent-generator.sh qa` call, advance the contract to `dispatched`, and spawn it with the printed Agent-call parameters.
- QA returns the structured verification payload only. It never writes `{verification_path}`. The main session applies the no-tool circuit breaker. If it triggers (unavailable tools are a provisioning failure), do not persist verification, advance state, or retry the same prompt. Otherwise the main session advances the observed contract through `running` and `awaiting_review`. It then checks the payload and pipes it to `scripts/write-verification.sh "{verification_path}"`.
- On writer or gate failure, move the contract to `blocked` and stop. Mark it `verified` only after deterministic gate success. Keep the phase-level verification frozen as the original FAIL.

**Known-issue sync and QA task description**:
    - After the main-session writer persists `{verification_path}`, run `track-known-issues.sh sync-verification "{phase-dir}" "{verification_path}"` without suppressing failure. A sync failure moves the QA contract to `blocked` and stops state advancement.
    - **Include in QA task description:** "In addition to verifying the remediation plan's own must_haves, you MUST re-verify each original FAIL from the VERIFICATION HISTORY section. For each FAIL_ID: if classified as code-fix, verify the code now matches the plan. If classified as doc-fix, verify the named documentation path now contains the required content. If classified as plan-amendment, verify the original PLAN.md now contains the actual approach and rationale. If classified as process-exception, verify the exception is documented with non-fixable justification and that the justification is credible for this FAIL. If code-fix, doc-fix, or plan-amendment still appears viable, keep the FAIL open. Any original FAIL that none of these four paths addresses is still a FAIL."
    - When a KNOWN ISSUES block is present, **include in QA task description:** "Tracked phase known issues are not informational in remediation rounds. Re-check every carried known issue from `known_issues_input` / `known_issue_resolutions`. Return only still-blocking issues in `pre_existing_issues`. If you verify a carried issue as an `accepted-process-exception`, omit it from `pre_existing_issues`. Confirm that the accepted non-blocking disposition is credible for this phase. Rely on the matching `known_issue_outcomes` entry to preserve visibility after the blocking registry clears. A clean remediation QA run must return an empty `pre_existing_issues` array for all resolved or accepted non-blocking carried issues so `{phase-dir}/known-issues.json` can clear."
      - The deterministic gate checks structural evidence only. During this re-verification step, QA must decide whether the evidence justifies a `process-exception`. When the original FAIL still appears fixable via code or plan amendment, documentation alone is insufficient.

**Deterministic gate**:
  - Run the deterministic gate:
    ```bash
    bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-result-gate.sh" "{phase-dir}"
    ```
    **Follow `qa_gate_routing` output exactly, with no exceptions, no judgment, no rationalization. Do NOT evaluate whether a failure looks justified or acceptable. Do NOT treat a failure as minor. The gate script already made the decision:**
    - `qa_gate_routing=PROCEED_TO_UAT` → advance to done: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-remediation-state.sh advance {phase-dir}`, then **refresh verify context before entering Verify mode**:
      ```bash
      bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-verify-context-for-uat.sh "{phase-dir}"
      ```
      Use this fresh verify context and **continue directly into Verify mode** for the phase
    - `qa_gate_routing=REMEDIATION_REQUIRED` → start new round: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/qa-remediation-state.sh needs-round {phase-dir}`, loop back to stage=plan. If `qa_gate_known_issues_override=true`, unresolved tracked known issues remain in `{phase-dir}/known-issues.json`.
    - `qa_gate_routing=QA_RERUN_REQUIRED` → re-spawn QA immediately (max 2 retries per round).
      - If `qa_gate_deviation_override=true`, tell QA: "Previous QA run found PASS but SUMMARY.md files contain {qa_gate_deviation_count} deviations that were not reflected as FAIL checks. Each deviation MUST become a FAIL check, do not rationalize deviations as acceptable."
      - If `qa_gate_plan_coverage` is present, tell QA: "Previous QA run only verified {qa_gate_plans_verified_count}/{qa_gate_plan_count} plans. Every plan in the phase must be verified, include all plan IDs in plans_verified."
      - If QA still fails to produce valid output, treat as REMEDIATION_REQUIRED.

    The gate output can also carry these override flags:
    - **When `qa_gate_metadata_only_override=true`** (routing will be `REMEDIATION_REQUIRED`): Display `⚠ QA remediation round made no implementation changes, only planning/documentation updates. The round still depends on a code-fix path (or omitted fail_classifications), so the gate cannot treat the original failures as resolved without implementation changes. ${qa_gate_phase_deviation_count} phase deviations remain recorded.` This override is the deterministic safety net for rounds that still depend on implementation changes. Pure plan-amendment rounds can pass only after the original plan changes. Pure process-exception rounds still need planning or remediation-artifact evidence. Delivered docs or README changes alone do not count. The next round's `stage=plan` MUST classify each FAIL as code-fix, doc-fix, plan-amendment, or process-exception per the Deviation Classification rules above.
    - **When `qa_gate_process_exception_evidence_missing=true`** (routing will be `REMEDIATION_REQUIRED`): Display `⚠ QA remediation round has a clean verification result, but the gate cannot find recorded remediation-artifact evidence. Record an existing remediation RNN-PLAN.md/RNN-SUMMARY.md or a valid original phase PLAN.md before treating the process-exception as resolved.` Continue with a new remediation round via `/meridian:transit`.
    - **When `qa_gate_round_change_evidence_empty=true`** (routing will be `REMEDIATION_REQUIRED`): This flag fires only for a round that includes `code-fix` classifications. Display `⚠ QA remediation round recorded no change evidence, both files_modified and commit_hashes were empty. A PASS without any recorded changed files or commits cannot resolve prior FAILs.` The next round must produce real code/plan changes or capture justified remediation evidence instead of an empty summary.
    - **When `qa_gate_round_change_evidence_unavailable=true`** (routing will be `REMEDIATION_REQUIRED`): This flag applies only to rounds that include `code-fix` classifications. Pure `plan-amendment` and `process-exception` rounds rely on their own evidence paths (source-plan coverage and process-exception artifact evidence) instead of code change evidence. Display `⚠ QA remediation round recorded change evidence that the gate cannot verify as current-round work. Either the recorded files match no committed or current round-local remediation-artifact change after the source verification commit, or the gate cannot prove that the referenced commit_hashes belong to this round, so it cannot trust the changed files.` Restore explicit files_modified entries and/or round-local commit evidence anchored to the remediation round before treating the failures as resolved.

- **stage=done:** Re-compute verify context, then proceed to Verify mode (UAT) for the phase:
  ```bash
  bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-verify-context-for-uat.sh "{phase-dir}"
  ```
  Use this fresh verify context for the Verify mode CHECKPOINT loop.

**QA Remediation + UAT blocking**: QA remediation is a pre-UAT route only. Before any UAT state or artifact exists for a phase, active QA remediation blocks UAT and `needs_qa_remediation` takes priority over `needs_verification`. Once any UAT state or artifact exists for that phase, stay in the UAT lane. Stale QA remediation metadata remains on disk for traceability but is dormant and must not resume automatically.

**all_done + natural language**: If the working input describes new work (bug, feature, task) and state is `all_done`, route to Add Phase mode instead of Archive. Add Phase handles codebase context loading and research internally. Do NOT spawn an Explore agent or do ad-hoc research before entering the mode.

**UAT remediation default**: When `next_phase_state=needs_uat_remediation`, plain `/meridian:transit` must read that phase's UAT report and continue remediation directly. Do NOT require the user to manually specify `--discuss` or `--plan`.

**Milestone UAT recovery**: When `milestone_uat_issues=true` and active phases are empty, the latest shipped milestone contains unresolved UAT issues. Present the user with three options:
| Choice | Outcome |
| --- | --- |
| (a) Fix the UAT issues | Create remediation phases. |
| (b) Start fresh | Begin new work and ignore the stale UAT. |
| (c) Skip for now | Keep the issues so they re-trigger next session. |

Use `milestone_uat_count` to determine how many phases the issues affect. When `milestone_uat_count` > 1, parse `milestone_uat_phase_dirs` (pipe-separated) to read all UAT reports and display a consolidated issue summary. Use `milestone_uat_major_or_higher` to determine severity context.

**Remediation + require_phase_discussion**: Both in-phase UAT remediation and milestone-level remediation phases skip the discussion step via pre-seeded phase context files. When `uat-remediation-state.sh get-or-init` runs for in-phase remediation, it appends the UAT report to the existing `{NN}-CONTEXT.md` and adds `pre_seeded: true` to its frontmatter. This keeps the original discussion context and still satisfies the `require_phase_discussion` gate. Milestone remediation phases created by `create-remediation-phase.sh` generate a fresh `{NN}-CONTEXT.md` with `pre_seeded: true` (populated from the source UAT report). Both paths use the same `pre_seeded` mechanism so `suggest-next.sh` handles them uniformly.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

**Todo lifecycle:** `scripts/resolve-todo-item.sh`, `scripts/todo-details.sh`, and
`scripts/todo-lifecycle.sh`.

**Re-verification:** `scripts/compile-verify-context-for-uat.sh`,
`scripts/extract-uat-resume.sh`, `scripts/normalize-plan-filenames.sh`, and
`scripts/prepare-reverification.sh`.

**UAT remediation:** `scripts/uat-remediation-state.sh` and
`scripts/validate-uat-remediation-artifact.sh`.

**Agent and recovery support:** `scripts/extract-skill-follow-up-files.sh` and `scripts/migrate-orphaned-state.sh`.
