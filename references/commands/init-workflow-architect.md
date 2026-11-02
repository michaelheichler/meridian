When `RESOLVED_BACKEND` is `workflow`, follow `{plugin-root}/references/workflow-spawn-protocol.md`.
The default Architect role permits `Write`.
Its schema 3 contract requires a granted write capability or an explicit `--read-only-role architect` declaration.
The Architect returns discovery and phase JSON in its report and writes nothing.
Issue the contract as read-only.

```bash
PROJECT_ROOT=$(pwd)
CONTROL_ROOT="$PROJECT_ROOT/.lbwc-planning"
ARCHITECT_BRIEF="draft initial requirements and roadmap"
CONTRACT_PATH=$(bash "{plugin-root}/scripts/task-contract.sh" issue "$PROJECT_ROOT" "init-architect" --command init --role architect --team solo --job "$ARCHITECT_BRIEF" --control-root "$CONTROL_ROOT" --requested-backend workflow --resolved-backend workflow --read-only-role architect) || exit 1
TASK_ID=$(basename "$CONTRACT_PATH" .json)
GENERATOR_OUTPUT=$(bash "{plugin-root}/scripts/agent-generator.sh" architect --job "$ARCHITECT_BRIEF" --contract "$CONTRACT_PATH" --task-id "$TASK_ID" --control-root "$CONTROL_ROOT" --execution-backend workflow) || exit 1
NAME=$(printf '%s\n' "$GENERATOR_OUTPUT" | awk '/^SPAWN_READY/{print $2}')
WORKFLOW_OUTPUT=$(bash "{plugin-root}/scripts/workflow-generator.sh" solo architect --job "$ARCHITECT_BRIEF" --contract "$CONTRACT_PATH" --task-id "$TASK_ID" --name "$NAME" --control-root "$CONTROL_ROOT") || exit 1
bash "{plugin-root}/scripts/task-contract.sh" state "$PROJECT_ROOT" "$TASK_ID" dispatched >/dev/null || exit 1
SCRIPT_PATH=$(printf '%s\n' "$WORKFLOW_OUTPUT" | awk '/^  path:/{print $2}')
```

Read the emitted `Agent-call parameters:` and `SPAWN_READY <name>` line, which the code captures as `NAME`.
Use only that printed name, never an invented name.
Read the `Workflow-call parameters:` block and the following `WORKFLOW_READY <task-id>` line.
Call `Workflow` exactly once with `scriptPath` set to `SCRIPT_PATH`.
Never pass `script` or inline or paraphrase the rendered file contents into the call.
The `PreToolUse` guard on `Workflow` independently checks the path against the registered digest.
If the guard denies the call, stop without a fallback.
`Workflow` runs the Architect in the background.
Its tool result reports only the launch, not the Architect report.
Before Step 7d validation and persistence, wait for the terminal result from that run.
Only a `user_decision_required` result returns control to the user.
For that result, ask exactly one bounded `AskUserQuestion`.
Every other terminal result carries the Architect report.
Validate it exactly like the `in_process` branch above.
