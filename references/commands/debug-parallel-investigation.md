For the ambiguous path (`INVESTIGATION_MODE=parallel`), create three independent solo command contracts with distinct hypothesis-focused task briefs. Issue the contracts three times, once for each hypothesis, and generate and dispatch each contract before any live spawn:

```bash
PROJECT_ROOT=$(pwd)
BUG_DESC="{bug description from Step 1}"
RESEARCH_CONTEXT=$(bash "{plugin-root}/scripts/compile-research-context.sh" .meridian "$BUG_DESC" 2>/dev/null || echo "")
CAUSE_BRIEF="Hypothesis: cause. Investigate the most likely root cause of $BUG_DESC; gather evidence for and against this cause. Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context."
AREA_BRIEF="Hypothesis: codebase area. Investigate which codebase area, component, boundary, or execution path owns $BUG_DESC; gather evidence for and against this area. Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context."
EVIDENCE_BRIEF="Hypothesis: confirming evidence. Investigate which reproduction, log, test, trace, or other evidence would confirm or reject the competing explanations for $BUG_DESC; gather that evidence. Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context."

CAUSE_CONTRACT_PATH=$(bash "{plugin-root}/scripts/task-contract.sh" issue "$PROJECT_ROOT" "debug-investigate-{task-slug}-cause" --command debug --role debugger --team solo --job "$CAUSE_BRIEF") || exit 1
CAUSE_TASK_ID=$(basename "$CAUSE_CONTRACT_PATH" .json)
bash "{plugin-root}/scripts/agent-generator.sh" debugger --job "$CAUSE_BRIEF" --contract "$CAUSE_CONTRACT_PATH" --task-id "$CAUSE_TASK_ID" || exit 1
bash "{plugin-root}/scripts/task-contract.sh" state "$PROJECT_ROOT" "$CAUSE_TASK_ID" dispatched >/dev/null || exit 1

AREA_CONTRACT_PATH=$(bash "{plugin-root}/scripts/task-contract.sh" issue "$PROJECT_ROOT" "debug-investigate-{task-slug}-area" --command debug --role debugger --team solo --job "$AREA_BRIEF") || exit 1
AREA_TASK_ID=$(basename "$AREA_CONTRACT_PATH" .json)
bash "{plugin-root}/scripts/agent-generator.sh" debugger --job "$AREA_BRIEF" --contract "$AREA_CONTRACT_PATH" --task-id "$AREA_TASK_ID" || exit 1
bash "{plugin-root}/scripts/task-contract.sh" state "$PROJECT_ROOT" "$AREA_TASK_ID" dispatched >/dev/null || exit 1

EVIDENCE_CONTRACT_PATH=$(bash "{plugin-root}/scripts/task-contract.sh" issue "$PROJECT_ROOT" "debug-investigate-{task-slug}-evidence" --command debug --role debugger --team solo --job "$EVIDENCE_BRIEF") || exit 1
EVIDENCE_TASK_ID=$(basename "$EVIDENCE_CONTRACT_PATH" .json)
bash "{plugin-root}/scripts/agent-generator.sh" debugger --job "$EVIDENCE_BRIEF" --contract "$EVIDENCE_CONTRACT_PATH" --task-id "$EVIDENCE_TASK_ID" || exit 1
bash "{plugin-root}/scripts/task-contract.sh" state "$PROJECT_ROOT" "$EVIDENCE_TASK_ID" dispatched >/dev/null || exit 1
```

Keep `RESEARCH_CONTEXT` only when non-empty. Include it, the accepted-exception semantics, compact source metadata, todo detail, or sparse enrichment only when present. Each report must include the no-tool circuit breaker result for unrelated failures.

Read every emitted `Agent-call parameters:` block and `SPAWN_READY` line. In one assistant message/turn, spawn all three named contracts with three parallel Agent-call blocks, one per generated debugger. Use only each printed `subagent_type`, `name`, and `model`. Do not add any other Agent-call fields. These three debuggers investigate simultaneously. Wait for all three `debugger_report`s before choosing an implementation or issuing an implementation contract.

Before composing each parallel Debugger task description, evaluate installed skills visible in system context in two passes. Derive technical domains from the assigned hypothesis, issue metadata, logs, errors, files, and bounded enrichment. Prefer these signals to generic stack guesses. Select all materially helpful direct skills and narrowly adjacent support skills. The task description for each debugger MUST begin with exactly one explicit `<skill_activation>` or `<skill_no_activation>` block, then name its assigned hypothesis. State the skill outcome in each response and cite bounded enrichment when it influenced the choice. After calling `Skill(...)`, read only relevant follow-up files named by the skill. Do not scan entire skill folders or read unrelated references.

If you preselected skills, run `bash "{plugin-root}/scripts/extract-skill-follow-up-files.sh" "{all preselected skill names from the activation block}" 2>/dev/null || true` for each assigned hypothesis. Render `{plugin-root}/references/skill-activation-payload.md` and prepend it to each child prompt. Include research context only when `compile-research-context.sh` returns content. Include todo detail or sparse enrichment only when it has signal.

Use this task description for each of the three parallel debuggers, replacing `{assigned hypothesis}` and `{hypothesis brief}` with that contract's values:

```text
Bug investigation. Effort: {EFFORT_PROFILE}.
<skill_activation>
{Rendered skill activation payload for this assigned hypothesis.}
</skill_activation>
Assigned hypothesis: {assigned hypothesis}.
Hypothesis brief: {hypothesis brief}.
<accepted_exception_debug_semantics>
{Paste the shared accepted-exception semantics from Step 1.}
</accepted_exception_debug_semantics>
Bug report: {description}.
{Include research, detail, and sparse enrichment only when present.}
Working directory: {pwd}.
If `.meridian/codebase/META.md` exists, read ARCHITECTURE.md, CONCERNS.md, PATTERNS.md, and DEPENDENCIES.md (whichever exist) before investigating.
Evaluate the assigned hypothesis, reproduce, gather evidence, and diagnose. Return `debugger_report` using `{plugin-root}/references/handoff-schemas.md`, with an explicit `resolution_observation` of `already_fixed`, `needs_change`, or `inconclusive`, exact diagnosed product file paths, proposed changes, verification commands, and pre-existing issues. Also evaluate available MCP tools in your system context relevant to this investigation and note them in the task context.
Do not edit files, write planning artifacts, run mutating Bash or Git commands, ask user questions, or claim final session ownership.
```

After all three reports return, the main session performs the synthesis sequentially. Compare the reports and produce confidence-ranked evidence for each hypothesis, explicitly marking each as `confirmed` or `rejected`, retaining the evidence that supports or contradicts it, and de-duplicating contributing factors and pre-existing issues. Only after this synthesis may the main session select the validated root cause and decide whether to issue the contract-scoped implementation debugger.
