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

**Guard:** Initialized. Requires position + name.
- If args are missing, STOP "Usage: `/meridian:transit --insert <position> <phase-name>`"
- If the position is invalid (out of range 1 to max+1), STOP with the valid range.
- If the insert goes before a completed phase, WARN + confirm.

**Steps:**
1. **Codebase context**: If `.meridian/codebase/META.md` exists, read ARCHITECTURE.md and CONCERNS.md (whichever exist) from `.meridian/codebase/`. Use this to inform phase goal scoping and identify relevant modules/services.
2. Parse the args into position (int), phase name, --goal (optional), and slug (lowercase hyphenated). Format the position as a zero-padded two-digit `{NN}` (for example, position 3 is `03`).
3. Identify renumbering. All phases >= position shift up by 1.
4. Renumber dirs in REVERSE order. Rename dir `{NN}-{slug}` -> `{NN+1}-{slug}`. Rename every number-prefixed internal artifact (`PLAN`, `SUMMARY`, `RESEARCH`, `CONTEXT`, `UAT`, `VERIFICATION`, and per-plan `{NN}-{MM}-*` files). Update `phase:` frontmatter. Update `depends_on` references.
5. Create dir: `mkdir -p .meridian/phases/{NN}-{slug}/` (with `{NN}` zero-padded).
6. **Problem research (conditional)**: If the arguments include a problem description, follow `references/agent-spawn-protocol.md`. Issue a solo `scout` command contract for job `research inserted phase {NN}` with `{phase-dir}/{NN}-RESEARCH.md` as its exact write allowance. Run the generic `scripts/agent-generator.sh scout` call, advance the contract to `dispatched`, and spawn it with the printed Agent-call parameters. Omit team and worktree fields. Do not re-resolve model, effort, or turns. Evaluate relevant skills and MCP tools, then render `references/skill-activation-payload.md`. After Scout completes, confirm the file is valid before using it. Stop and report a contract or generator failure verbatim.
  If the skill evaluation preselected one or more skills, run `bash "/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/extract-skill-follow-up-files.sh" "{all preselected skill names from the activation block}" 2>/dev/null || true` before spawning the insert-phase Scout. If the helper prints a `<skill_follow_up_files>` block, paste it immediately after the follow-up-read sentence in the spawned payload. Otherwise omit that block.
  Render the prompt prefix from `/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/references/skill-activation-payload.md` with the local `skill_calls`, task-specific `no_skill_reason`, and optional helper-emitted `follow_up_files_block`. Prepend the rendered bytes to the child prompt so the rendered skill outcome tag is its first line. Do not paste the template path, variables, or an unresolved `@` include into the child prompt.
7. Update ROADMAP.md. Insert the new phase entry + details at position. If Scout findings are available, use them. Renumber subsequent entries/headers/cross-refs. Update the progress table.
8. If `.meridian/CONTEXT.md` exists, rewrite it to reflect the updated milestone decomposition (phase count/grouping, ordering, scope coverage, and requirement mapping). Preserve project-level key decisions and deferred ideas where still valid.
9. Update STATE.md phase total: `bash /tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/update-phase-total.sh .meridian --inserted {position}` (where {position} is the insert position from step 2).
10. **Phase mutation commit boundary (conditional):**
    ```bash
   PG_SCRIPT="/tmp/.meridian-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
    if [ -f "$PG_SCRIPT" ]; then
      bash "$PG_SCRIPT" commit-boundary "insert phase {NN}-{slug} at position {position}" .meridian/config.json
    else
      echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
    fi
    ```
    If `.meridian/` changed, `planning_tracking=commit` commits it. Other modes no-op.
11. Present the Phase Banner with renumber count, phase changes, file list, and Next Up.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/extract-skill-follow-up-files.sh`
- `scripts/planning-git.sh`
- `scripts/update-phase-total.sh`
