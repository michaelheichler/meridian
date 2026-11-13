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

Use the working input from transit input parsing, which starts with the user input above and applies todo resolution plus ref cleanup.

**Guard:** Initialized. Requires phase name in the working input.
- If the name is missing, STOP "Usage: `/meridian:transit --add <phase-name>`"

**Steps:**

**Phase setup (steps 1-4):**
**Step 1, codebase context**: If `.meridian/codebase/META.md` exists, read ARCHITECTURE.md and CONCERNS.md (whichever exist) from `.meridian/codebase/`. Use this to inform phase goal scoping and identify relevant modules/services.
**Step 2, parse arguments:** Phase name (first non-flag arg), --goal (optional), slug (lowercase hyphenated).
**Step 3, next number:** Highest in ROADMAP.md + 1, zero-padded.
**Step 4, create directory:** `mkdir -p .meridian/phases/{NN}-{slug}/`
5. **Problem research (conditional)**: If the working input contains a problem description (bug report, feature request, multi-sentence intent) rather than a bare phase name:
  **Scout contract and spawn:** Follow `references/agent-spawn-protocol.md`. Issue a solo `scout` command contract for job `research added phase {NN}` with `{phase-dir}/{NN}-RESEARCH.md` as the exact write allowance. Run the generic `scripts/agent-generator.sh scout` call, advance the contract to `dispatched`, and use the printed Agent-call parameters and `SPAWN_READY` name exactly. Omit team and worktree fields. Do not re-resolve the model, effort, and turns. Stop and report a contract or generator failure instead of silently running an uncontracted fallback.
  Pass `<output_path>{phase-dir}/{NN}-RESEARCH.md</output_path>` in the Scout prompt so the contracted Scout writes its findings directly.
  **Skill selection**: Before composing the Scout task description, evaluate installed skills visible in your system context. Read each skill's description. Select all materially helpful installed skills for this task, including adjacent/supporting domain skills that the prompt, logs, error text, related files, or stack context surface. Do not select only the single most direct skill. The Scout prompt MUST begin with exactly one explicit skill outcome block. When orchestration preselects one or more installed skills, use `<skill_activation>{For each selected skill: "Call Skill({skill-name})"}</skill_activation>`. When orchestration preselects none, use 

```text
<skill_no_activation>Evaluated installed skills for this task. No skills were preselected at orchestration time. Reason: {brief task-specific reason}.</skill_no_activation>
```

. Never omit both blocks silently. After evaluating, state the skill outcome in your response (for example, "Skills: activating {skill-name}" or "Skills: none preselected. {reason}") so the user can see it before you spawn the agent. For example, a prompt or error that mentions SwiftData needs `swiftdata` alongside relevant test/build/debug skills. After calling `Skill(...)`, read the specific files that its instructions reference for the active task. This covers additional files, sibling docs, and follow-up read steps. Do this before reasoning or acting. Do not scan entire skill folders or read unrelated references.
  **Skill follow-up files**: If orchestration preselected one or more skills, run `bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/extract-skill-follow-up-files.sh" "{all preselected skill names from the activation block}" 2>/dev/null || true` before spawning the add-phase Scout. If the helper prints a `<skill_follow_up_files>` block, paste it immediately after the follow-up-read sentence in the spawned payload. Otherwise omit that block.
  Render the prompt prefix from `/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/references/skill-activation-payload.md` with the local `skill_calls`, task-specific `no_skill_reason`, and optional helper-emitted `follow_up_files_block`. Prepend the rendered bytes to the child prompt so the rendered skill outcome tag is its first line. Do not paste the template path, variables, or an unresolved `@` include into the child prompt.
  **MCP context:** Also evaluate available MCP tools. If any MCP servers provide documentation, search, or data retrieval capabilities relevant to this research, note them in the Scout's task context.
  - After Scout completes, check the file exists (read first line).
  - Use Scout findings to write an informed phase goal and success criteria in ROADMAP.md.
  - On failure, log a warning and write the phase goal from the working input alone. Do not block.
  - **This eliminates duplicate research.** Plan mode step 3 checks for an existing RESEARCH.md. If it finds one, it skips Scout.
6. Update ROADMAP.md. Append the phase list entry. Append the Phase Details section. If Scout findings are available, use them there. Add the progress row.
7. If `.meridian/CONTEXT.md` exists, rewrite it to reflect the updated milestone decomposition (phase count/grouping, ordering, scope coverage, and requirement mapping). Preserve project-level key decisions and deferred ideas where still valid.
8. Update STATE.md phase total: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/update-phase-total.sh .meridian`
9. **Phase mutation commit boundary (conditional):**
   ```bash
  PG_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
   if [ -f "$PG_SCRIPT" ]; then
     bash "$PG_SCRIPT" commit-boundary "add phase {NN}-{slug}" .meridian/config.json
   else
     echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
   fi
   ```
   If `.meridian/` changed, `planning_tracking=commit` commits it. Other modes no-op.
10. Present the Phase Banner with position and goal. Show a checklist for roadmap update + dir creation. Next Up is `/meridian:transit --discuss` or `/meridian:transit --plan`.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/extract-skill-follow-up-files.sh`
- `scripts/planning-git.sh`
- `scripts/update-phase-total.sh`
