## Main-session Decision Handoffs

Only the main session can call `AskUserQuestion`. Before each `AskUserQuestion`
call, the main session follows `references/meridian-brand-essentials.md`. A worker
that reaches a decision boundary returns the `user_decision_required` JSON from
`references/subagent-contracts.md`. The worker does not mutate state or claim a
todo until the main session responds. It also does not start the next stage
before that response. A declined choice keeps the state and reports the
documented Next Up command.

**Execute-mode invariant:** Parallel execution requires two things. Dependency-aware routing must find real parallel delegate work, and the live tool set must be able to create real team-scoped teammates. If routing selects serialized subagents or turbo/internal direct, execute mode must fall back to explicit non-team execution. The same fallback applies to a live tool set that cannot establish real team semantics. Never simulate a team with background `Agent` spawns that lack `team_name`.

**Spawn path (hard branch):** After the frozen snapshot exists, choose exactly one spawn path. A main session must not run more than one.

- If `snapshot.resolved_backend` is `tmux`, do not follow `execute-protocol.md` native Agent spawn. After generation and `state ... dispatched`, run `scripts/tmux-spawn-group.sh dispatch` as documented below.
- If `snapshot.resolved_backend` is `in_process`, follow `execute-protocol.md` native Agent spawn. Do not run the tmux spawn driver.
- If `snapshot.resolved_backend` is `workflow`, do not follow `execute-protocol.md` native Agent spawn and do not run the tmux spawn driver. After generation and `state ... dispatched`, render and register the grouping's workflow script and call `Workflow` as documented below.

Read `/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/references/execute-protocol.md` for plan loading, contracts, verification, and commits. Use its Agent spawn steps only on the `in_process` branch.

**Orchestrator read-scope:** Do NOT read product source files. Your job is orchestration. Read plans, check summaries, and spawn Dev for remaining work. If you need product-code understanding to route or sequence, delegate that to Dev.

Before reading:
**Step 0, pre-normalize filenames:**
    ```bash
    NORM_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/normalize-plan-filenames.sh"
    if [ -f "$NORM_SCRIPT" ]; then
      bash "$NORM_SCRIPT" "{phase_dir}"
    fi
    ```
**Step 1, parse arguments:** Phase number (optional, auto-detect it), --effort, --skip-qa, --plan=NN.
2. **Run execute guards:**
   - If not initialized, STOP "Run /meridian:init first."
   - If the phase dir has no PLAN.md, STOP "Phase {NN} has no plans. Run `/meridian:transit --plan {NN}` first."
   - If all plans have SUMMARY.md, cautious/standard -> WARN + check with the user. Confident/pure-vibe -> warn + auto-continue.
   - **Milestone path guard**: If `{phase_dir}` contains `.meridian/milestones/`, STOP "Cannot execute inside archived milestones." This prevents writing artifacts into shipped milestone directories.
3. **Compile context**: If `config_context_compiler=true`, run:
   - `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-context.sh {phase} dev {phases_dir} {plan_path}`
   - `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/compile-context.sh {phase} qa {phases_dir}`
   Include compiled context paths in Dev and QA task descriptions. When referencing `.context-dev.md`, describe it as: "compiled context. It includes milestone scope decisions (decomposition rationale, scope boundaries, cross-phase key decisions). It also includes phase operational context (goal, conventions, active plan, research findings, changed files, code slices)". When referencing `.context-qa.md`, describe it as: "compiled context. It includes milestone scope decisions and phase verification context (success criteria, requirements, conventions to check)".
  If `TODO_SELECTED_JSON` already exists from the numbered-todo path and `DETAIL_STATUS=ok`, reuse the already-loaded detail in the Dev task description. Use `Extended context (from todo detail): {detail.context value}. Related files: {detail.files, comma-separated, or omit if empty}.` as its text, with placeholders filled in.

  Otherwise, for a ref hash that Input Parsing extracted, load extended detail now:
   ```bash
  bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/todo-details.sh get {hash}
   ```
  Parse the JSON output. If `status` is `"ok"`, include the detail in the Dev task description as `Extended context (from todo detail): {detail.context value}. Related files: {detail.files, comma-separated, or omit if empty}.`, with the placeholders filled in. If `status` is `"not_found"` or `"error"`, run `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/todo-lifecycle.sh detail-warning {hash}` and continue without detail. Do not block. This provides the executing agent with the rich context that motivated the work item.

Then freeze or check the runtime snapshot as in Frozen snapshot spawn dispatch. In Execute mode, the `cancel` subcommand of `scripts/runtime-snapshot.sh` still writes only `{PHASE_DIR}/.runtime-cancelled.json`. After the snapshot exists, take the hard spawn branch above and, on `in_process`, read the protocol file and execute Steps 2-5 including Agent spawn. On `tmux`, use the protocol for non-spawn steps only and dispatch through the spawn driver.

## Frozen snapshot spawn dispatch

This is the same dispatch as `/meridian:build`, where Execute mode already resolved `{PHASE_DIR}` and `{PROJECT_ROOT}`, and `{LINK}` is the plugin root from Context. Cite `{LINK}/references/tmux-spawn-protocol.md` on the tmux branch, and do not invent a second orchestrator.

If `{PHASE_DIR}/.runtime-snapshot.json` exists, copy snapshot backends into CLI flags. If it does not exist, do not copy them. Control root is `{PROJECT_ROOT}/.meridian`, the freeze `--planning-dir`. Native `in_process` with no freeze must not `jq` a missing snapshot. Leave `OPEN_BACKEND_ARGS` empty and keep the selected `in_process` backends. When the snapshot exists and `snapshot.requested_backend` equals `snapshot.resolved_backend`, pass those values plus `--control-root` and `--assert-snapshot` so `open` cannot disagree with the snapshot. When they differ, that is the already-frozen `comms_fallback` case. Omit the schema 3 backend flags (`open` requires matching backends), then follow the native Agent path.

```bash
SNAPSHOT_PATH="{PHASE_DIR}/.runtime-snapshot.json"
CONTROL_ROOT="{PROJECT_ROOT}/.meridian"
OPEN_BACKEND_ARGS=()
if [ -f "$SNAPSHOT_PATH" ]; then
  REQUESTED_BACKEND=$(jq -r '.requested_backend' "$SNAPSHOT_PATH")
  RESOLVED_BACKEND=$(jq -r '.resolved_backend' "$SNAPSHOT_PATH")
  if [ "$REQUESTED_BACKEND" = "$RESOLVED_BACKEND" ]; then
    OPEN_BACKEND_ARGS=(--requested-backend "$REQUESTED_BACKEND" --resolved-backend "$RESOLVED_BACKEND" --control-root "$CONTROL_ROOT" --assert-snapshot "$SNAPSHOT_PATH")
  fi
fi
CONTRACT_PATH=$(bash "{LINK}/scripts/task-contract.sh" open "$PLAN_PATH" "{PROJECT_ROOT}" "$TASK_NAME" --role "$ROLE" --team "$TEAM_MODE" --group "$GROUP_NAME" --job "$BRIEF" "${OPEN_BACKEND_ARGS[@]}" "${CONTRACT_ALLOWANCE_ARGS[@]}")
TASK_ID=$(basename "$CONTRACT_PATH" .json)
```

Pass the contract path, task id, job, team mode, and identical allowance arguments to one generator invocation. If `OPEN_BACKEND_ARGS` is non-empty, pass `--execution-backend "$RESOLVED_BACKEND"` so the generator matches a schema 3 contract. Schema 2 native generation without a freeze, and the frozen `comms_fallback` case, must omit that override. Append `--execution-backend "$RESOLVED_BACKEND"` to the `agent-generator.sh` call in `execute-protocol.md` only in that schema 3 case. The main session owns `open`. Workers never create or modify contracts. If generation fails, leave that grouping contract `planned` and report the error.

Pass `snapshot.resolved_backend` to every `agent-generator.sh --execution-backend` invocation that follows a schema 3 open. Stop on contract, generator, preflight, provision, split-group, or bus failure. Do not silently switch to in-process except the already-frozen `comms_fallback` case above. Schema 2 generation omits `--execution-backend`.

If `snapshot.resolved_backend` is `in_process`, keep the native Agent path. Spawn every generated name together in the same turn with `Agent(...)` as `@references/agent-spawn-protocol.md` requires. Do not run `tmux-spawn-group.sh`.

If `snapshot.resolved_backend` is `tmux`, follow `{LINK}/references/tmux-spawn-protocol.md` on this branch only. Do not call native Agent. After generation and `state ... dispatched`, run the spawn driver. `MAIN_ID` is the live orchestrator session `${CLAUDE_SESSION_ID:-}`. If it is empty, fail closed.

   ```bash
   MAIN_ID="${CLAUDE_SESSION_ID:-}"
   [ -n "$MAIN_ID" ] || { echo "MERIDIAN: CLAUDE_SESSION_ID is required for tmux spawn" >&2; exit 1; }
   TIMEOUT_MS=$(jq -r '.tmux_execution.comms_latency_tolerance_ms' "$SNAPSHOT_PATH")
   CONTRACT_DIGEST=$(jq -r '.contract_digest' "$CONTRACT_PATH")
   bash "{LINK}/scripts/tmux-spawn-group.sh" dispatch --project-root "{PROJECT_ROOT}" --control-root "$CONTROL_ROOT" --main-id "$MAIN_ID" --contract-id "$TASK_ID" --contract-digest "$CONTRACT_DIGEST" --spawn-ready-text "$GENERATOR_OUTPUT" --job "$BRIEF" --timeout-ms "$TIMEOUT_MS"
   ```

   Observe the helper JSON summary as the grouping reports. Then continue contract state, verification, and commits from `execute-protocol.md`. After the grouping is terminal, apply protocol cleanup (`kill-agent` or `kill-session`) from the frozen cleanup policy.

If `snapshot.resolved_backend` is `workflow`, follow `{LINK}/references/workflow-spawn-protocol.md` on this branch only. Do not call native Agent and do not run `tmux-spawn-group.sh`. `workflow-generator.sh` requires the same grouping contract while it is still `planned`, so run it before the state transition below. Its call is `workflow-generator.sh <solo|pair|trio> "$ROLE" --job "$BRIEF" --contract "$CONTRACT_PATH" --task-id "$TASK_ID" --control-root "$CONTROL_ROOT"`, with the shape matching `$TEAM_MODE` for this grouping. Pass every name the prior generator invocation produced. Use `--name` for solo, or `--engineer-name`/`--critic-name`/`--testdev-name` for a pair or trio. For a pair or trio, also pass `--autonomy` read from `{PROJECT_ROOT}/.meridian/config.json`. Read the `Workflow-call parameters:` block and the `WORKFLOW_READY <task-id>` line that follows it. On any `workflow-generator:` stderr failure, stop and report the error verbatim, and leave the contract `planned`. After successful registration, run `state ... dispatched`.

   Call `Workflow` exactly once with `scriptPath` set to the path value from the `Workflow-call parameters:` block, checked against the `WORKFLOW_READY <task-id>` line that follows it. Never pass `script`, and never inline or paraphrase the rendered file into the call. The `PreToolUse` guard on `Workflow` independently revalidates the path against the registered digest. A denial is a stop, not a fallback trigger.

   `Workflow` runs the grouping in the background. Its own tool result reports only the launch (`taskId`, `runId`, `transcriptDir`, `scriptPath`), never the outcome. The manifest is still what `execute-protocol.md` reads for `state ... running`, but entry is not the same shape here. A workflow-spawned member's `agent()` step fires the same `SubagentStart` hook a native member's `Agent` call fires, confirmed on the host in `references/workflow-probe-findings.md`, Unknown D. It fires only for the one member the template has started so far. `references/agent-spawn-protocol.md` requires every admitted member spawned in one message. A native pair or trio reaches `running` together because of that. `templates/workflows/pair.js.tpl` instead awaits the engineer's `agent()` call before starting the critic's, and `templates/workflows/trio.js.tpl` awaits engineer, then `test-dev`, then critic. A workflow pair or trio is therefore never more than one member `running` at once. Run `state ... running` from that first `SubagentStart`, not from waiting on every admitted member to reach it, because the later members have not started yet. Closure is not read from the manifest alone. Observe the run's own terminal `result` first, not through native task or bus polling, and only after that result arrives read the manifest's `used`-or-`expired` state as confirmation before generating another grouping. A pair or trio requires this ordering. `templates/workflows/pair.js.tpl` and `templates/workflows/trio.js.tpl` retry the same registered names once per remediation round, so a member reads `used` between rounds while the grouping is still active. Reading the manifest alone at that moment would admit the next grouping too early. The terminal result is what marks the grouping done. The manifest corroborates it once observed, it does not substitute for it. When that result carries `user_decision_required`, ask exactly one bounded `AskUserQuestion` about continuing remediation, following `{LINK}/references/ask-user-question.md`. Any other terminal result is the grouping's report. Continue contract state, verification, and commits from `execute-protocol.md` exactly as the native path above. There is no pane or bus to clean up.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/normalize-plan-filenames.sh`
- `scripts/todo-details.sh`
- `scripts/todo-lifecycle.sh`
