For the serial path (`INVESTIGATION_MODE=serial`), compile optional prior research with `compile-research-context.sh` using the parsed bug description. Keep it only when non-empty. Include the accepted-exception semantics and compact source metadata when present. The report must include the no-tool circuit breaker result for unrelated failures.

```bash
PROJECT_ROOT=$(pwd)
DEBUG_BRIEF="{bug description from Step 1}"
CONTRACT_PATH=$(bash "{plugin-root}/scripts/task-contract.sh" issue "$PROJECT_ROOT" "debug-investigate-{task-slug}" --command debug --role debugger --team solo --job "$DEBUG_BRIEF") || exit 1
TASK_ID=$(basename "$CONTRACT_PATH" .json)
bash "{plugin-root}/scripts/agent-generator.sh" debugger --job "$DEBUG_BRIEF" --contract "$CONTRACT_PATH" --task-id "$TASK_ID" || exit 1
bash "{plugin-root}/scripts/task-contract.sh" state "$PROJECT_ROOT" "$TASK_ID" dispatched >/dev/null || exit 1
```

Read the emitted `Agent-call parameters:` and `SPAWN_READY` line. Spawn the Debugger with only its printed `subagent_type`, `name`, and `model`. Do not add any other Agent-call fields. This single debugger investigates sequentially. Before composing its task description, evaluate available MCP tools in your system context relevant to this investigation and note them in the task context. The serial task description must also include exactly one explicit `<skill_activation>` or `<skill_no_activation>` block and follow the same bounded skill-selection, research, detail, and no-tool-circuit-breaker requirements above.

Use this task description for the serial debugger:

```text
Bug investigation. Effort: {EFFORT_PROFILE}.
<skill_activation>
{Rendered skill activation payload, or the explicit no-activation outcome.}
</skill_activation>
<accepted_exception_debug_semantics>
{Paste the shared accepted-exception semantics from Step 1.}
</accepted_exception_debug_semantics>
Bug report: {description}.
{Include research, detail, and sparse enrichment only when present.}
Working directory: {pwd}.
If `.lbwc-planning/codebase/META.md` exists, read ARCHITECTURE.md, CONCERNS.md, PATTERNS.md, and DEPENDENCIES.md (whichever exist) before investigating.
Evaluate all relevant hypotheses, reproduce, gather evidence, and diagnose. Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context. Return `debugger_report` using `{plugin-root}/references/handoff-schemas.md`, with an explicit `resolution_observation` of `already_fixed`, `needs_change`, or `inconclusive`, exact diagnosed product file paths, proposed changes, verification commands, and pre-existing issues. Include the no-tool circuit breaker result for unrelated failures.
Do not edit files, write planning artifacts, run mutating Bash or Git commands, ask user questions, or claim final session ownership.
```
