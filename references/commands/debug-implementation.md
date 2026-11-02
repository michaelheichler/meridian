**Implementation after diagnosis:** If the validated `debugger_report` says `needs_change`, the main session must derive a de-duplicated list of exact existing or new product file paths from the report. Reject empty, directory, glob, planning-artifact, test-path, or unverified paths. If the report is `already_fixed` or `inconclusive`, do not issue an implementation contract and skip this entire block, including the execution-backend choice below.

**Choose the execution backend.** Follow step 0 of `{plugin-root}/references/workflow-spawn-protocol.md`, with `<control-root>` bound to `.lbwc-planning`. Use these literal `AskUserQuestion` fields when that step's `ask` branch applies:

- header: `Implementation execution`
- question: `Where should this implementation run? Workflow run applies it through a committed background script. Native spawn keeps the current single-agent implementation.`
- options:
  - `Workflow run`: Apply the fix through a committed workflow script in the background.
  - `Native spawn`: Keep the current native implementation spawn.
  - `Cancel implementation`: Investigate but do not apply this fix now.

On `Cancel implementation`, session status stays `investigating`. This gate applies only to this implementation spawn. The read-only investigation debuggers above always spawn `in_process`.

When `RESOLVED_BACKEND` is `in_process`, issue a new solo Debugger contract once per implementation job, repeating each exact path as a `--write-allowance` on both helpers:

```bash
IMPL_BRIEF="implement diagnosed debug fix: {one-line plan}. Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context."
CONTRACT_PATH=$(bash "{plugin-root}/scripts/task-contract.sh" issue "$PROJECT_ROOT" "debug-implement-{task-slug}" --command debug --role debugger --team solo --job "$IMPL_BRIEF" --write-allowance "{exact diagnosed product path}" [--write-allowance "{another exact diagnosed product path}"]) || exit 1
TASK_ID=$(basename "$CONTRACT_PATH" .json)
bash "{plugin-root}/scripts/agent-generator.sh" debugger --job "$IMPL_BRIEF" --contract "$CONTRACT_PATH" --task-id "$TASK_ID" --write-allowance "{exact diagnosed product path}" [--write-allowance "{another exact diagnosed product path}"] || exit 1
bash "{plugin-root}/scripts/task-contract.sh" state "$PROJECT_ROOT" "$TASK_ID" dispatched >/dev/null || exit 1
```

Read its emitted spawn values and invoke only printed `subagent_type`, `name`, and `model`.

When `RESOLVED_BACKEND` is `workflow`, follow `{plugin-root}/references/workflow-spawn-protocol.md`. Issue the same solo Debugger contract as a schema 3 contract, repeating each exact path as a `--write-capability file:{path}` instead of a `--write-allowance`:

```bash
CONTROL_ROOT="$PROJECT_ROOT/.lbwc-planning"
IMPL_BRIEF="implement diagnosed debug fix: {one-line plan}. Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context."
CONTRACT_PATH=$(bash "{plugin-root}/scripts/task-contract.sh" issue "$PROJECT_ROOT" "debug-implement-{task-slug}" --command debug --role debugger --team solo --job "$IMPL_BRIEF" --control-root "$CONTROL_ROOT" --requested-backend workflow --resolved-backend workflow --write-capability "file:{exact diagnosed product path}" [--write-capability "file:{another exact diagnosed product path}"]) || exit 1
TASK_ID=$(basename "$CONTRACT_PATH" .json)
GENERATOR_OUTPUT=$(bash "{plugin-root}/scripts/agent-generator.sh" debugger --job "$IMPL_BRIEF" --contract "$CONTRACT_PATH" --task-id "$TASK_ID" --control-root "$CONTROL_ROOT" --write-capability "file:{exact diagnosed product path}" [--write-capability "file:{another exact diagnosed product path}"] --execution-backend workflow) || exit 1
NAME=$(printf '%s\n' "$GENERATOR_OUTPUT" | awk '/^SPAWN_READY/{print $2}')
```

Read the emitted `Agent-call parameters:` and `SPAWN_READY <name>` from `GENERATOR_OUTPUT`, captured above as `NAME`, then render and register the workflow:

```bash
bash "{plugin-root}/scripts/workflow-generator.sh" solo debugger --job "$IMPL_BRIEF" --contract "$CONTRACT_PATH" --task-id "$TASK_ID" --name "$NAME" --control-root "$CONTROL_ROOT" || exit 1
bash "{plugin-root}/scripts/task-contract.sh" state "$PROJECT_ROOT" "$TASK_ID" dispatched >/dev/null || exit 1
```

Read the `Workflow-call parameters:` block and the `WORKFLOW_READY <task-id>` line that follows it. Call `Workflow` exactly once with `scriptPath` set to the printed `path` value. Never pass `script`, and never inline or paraphrase the rendered file into the call. The `PreToolUse` guard on `Workflow` independently revalidates the path against the registered digest. A denial is a stop, not a fallback trigger. `Workflow` runs the implementation in the background. Its own tool result reports only the launch, never the implementation report. Wait for the run's own terminal result. A `user_decision_required` result is the only path back to the user, ask exactly one bounded `AskUserQuestion` about it. Any other terminal result is the implementation debugger's report.

Either way, the implementation prompt names the exact contract paths, diagnosis, rejected hypotheses, and verification commands. Tell the debugger to implement only those paths and report evidence. Prohibit writing planning artifacts and asking user questions. Prohibit running Git commands. The implementation prompt MUST begin with exactly one explicit `<skill_activation>` or `<skill_no_activation>` block and must also evaluate available MCP tools relevant to this investigation. Include the exact instruction `Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context.` in the implementation task context. The main session runs verification and creates the fix commit after it passes.
