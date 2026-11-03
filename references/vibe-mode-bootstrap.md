## Main-session Decision Handoffs

Only the main session can call `AskUserQuestion`. Before each `AskUserQuestion`
call, the main session follows `references/lbwc-brand-essentials.md`. A worker
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

**Guard:** `.lbwc-planning/` exists but no PROJECT.md.

**Critical Rules (non-negotiable):**
- NEVER fabricate content. Only use what the user explicitly states.
- If the user's answer does not match the question, STOP, handle the request the user made instead, and let the user re-run the bootstrap.
- No silent assumptions. Ask follow-ups for gaps.
- Phases come from the user, not you.

**Constraints:** Do NOT explore/scan codebase (that is /lbwc:map). If `.lbwc-planning/codebase/META.md` exists, use the existing `.lbwc-planning/codebase/`.

**Brownfield detection:** `git ls-files` or Glob check for existing code.

**Steps:**
- **B1 (PROJECT.md)**: If $ARGUMENTS provided (excluding flags), use as description. Otherwise ask name + core purpose. Then call:
  ```
  bash /tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/bootstrap/bootstrap-project.sh .lbwc-planning/PROJECT.md "$NAME" "$DESCRIPTION"
  ```
- **B1.5 (Discovery Depth)**: Read `discovery_questions` and `active_profile` from the LBWC settings. Map profile to depth:

  | Profile | Depth | Questions |
  | --------- | ------- | ----------- |
  | yolo | skip | 0 |
  | prototype | quick | 1-2 |
  | default | standard | 3-5 |
  | production | thorough | 5-8 |

  If `discovery_questions=false`, force depth=skip. Store DISCOVERY_DEPTH for B2.

- **B2 (REQUIREMENTS.md, Discovery)**: Behavior depends on DISCOVERY_DEPTH:
  - **B2.1 (Domain Research)**: If DISCOVERY_DEPTH != skip:

    **Research setup (steps 1-4):**
    **Step 1:** Extract domain from user's project description (the $NAME or $DESCRIPTION from B1)
    **Step 2:** Follow `references/agent-spawn-protocol.md`. Do not resolve the model, effort, and turns separately. The generic generator prints the checked Agent-call parameters.
    **Step 3**: Before composing the Scout task description, evaluate installed skills visible in your system context. Read each skill's description. Select all materially helpful installed skills for this task, including adjacent/supporting domain skills that the prompt, logs, error text, related files, or stack context surface. Do not select only the single most direct skill. The Scout prompt MUST begin with exactly one explicit skill outcome block. When orchestration preselects one or more installed skills, use `<skill_activation>{For each selected skill: "Call Skill({skill-name})"}</skill_activation>`. When orchestration preselects none, use 

```text
<skill_no_activation>Evaluated installed skills for this task. No skills were preselected at orchestration time. Reason: {brief task-specific reason}.</skill_no_activation>
```

. Never omit both blocks silently. After evaluating, state the skill outcome in your response (for example, "Skills: activating {skill-name}" or "Skills: none preselected. {reason}") so the user can see it before you spawn the agent. For example, a prompt or error that mentions SwiftData needs `swiftdata` alongside relevant test/build/debug skills. After calling `Skill(...)`, read the specific files that its instructions reference for the active task. This covers additional files, sibling docs, and follow-up read steps. Do this before reasoning or acting. Do not scan entire skill folders or read unrelated references.
    **Step 3.25**: If orchestration preselected one or more skills, run `bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/extract-skill-follow-up-files.sh" "{all preselected skill names from the activation block}" 2>/dev/null || true` before spawning the bootstrap domain-research Scout. If the helper prints a `<skill_follow_up_files>` block, paste it immediately after the follow-up-read sentence in the spawned payload. Otherwise omit that block.
     Render the prompt prefix from `/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/references/skill-activation-payload.md` with the local `skill_calls`, task-specific `no_skill_reason`, and optional helper-emitted `follow_up_files_block`. Prepend the rendered bytes to the child prompt so the rendered skill outcome tag is its first line. Do not paste the template path, variables, or an unresolved `@` include into the child prompt.
    **Step 4:** Also evaluate available MCP tools in your system context. If any MCP servers provide documentation, search, or data retrieval capabilities relevant to this research topic, note them in the Scout's task context. This makes the Scout prioritize those tools over generic WebSearch/WebFetch where applicable.

    **Research execution (steps 5-8):**
    **Step 5:** Issue a solo `scout` command contract for job `bootstrap domain research` with `.lbwc-planning/domain-research.md` as the exact write allowance. Run the generic `scripts/agent-generator.sh scout` call from `references/agent-spawn-protocol.md`, advance the contract to `dispatched`, and capture its `SPAWN_READY` name. Stop and report any contract or generator failure verbatim.
    **Step 6:** Spawn the generated Scout with the exact Agent-call parameters printed by the generator. Prompt: "Research the {domain} domain. Write findings to <output_path>.lbwc-planning/domain-research.md</output_path> with ## Table Stakes, ## Common Pitfalls, ## Architecture Patterns, and ## Competitor Landscape. Use relevant MCP tools or WebSearch. Keep each section to 2-3 bullets."
    **Step 7:** Use the generated name for both `subagent_type` and `name`. Omit team and worktree fields. Do not re-resolve or override the model, effort, and turns.
    **Step 8:** On success, read `.lbwc-planning/domain-research.md` (Scout wrote it directly). Extract brief summary (3-5 lines max). Display to user: "◆ Domain Research: {brief summary}\n\n✓ Research complete. Now let's explore your specific needs..."
    **Step 9:** On failure, log warning "⚠ Domain research timed out, proceeding with general questions". Set RESEARCH_AVAILABLE=false, continue.
  - **B2.2 (Discussion Engine)**: Read `/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/references/discussion-engine.md` and follow its protocol.
    - Context for the engine: "This is a new project. No phases yet." Use project description + domain research (if available) as input.
    - If `.lbwc-planning/codebase/META.md` exists and `discussion_mode` in the settings is `"assumptions"` or `"auto"`, pass "Discussion mode: assumptions" to the engine. The engine's Step 1.7 will form evidence-backed assumptions from codebase context instead of asking questions from scratch.
    - The engine handles calibration, gray area generation, exploration, and capture. The Recommendation Principle applies during bootstrap. Lead with enterprise-standard recommendations for technical decisions, and present product decisions equally.
    - The output is `discovery.json` with answered/inferred/deferred arrays.
  - **If skip (yolo profile or discovery_questions=false):** Ask 2 minimal static questions sequentially, with one AskUserQuestion call per question:
    1. "What are the must-have features for this project?" Options: ["Core functionality only", "A few essential features", "Full feature set"]
    2. "Who will use this?" Options: ["Only me", "Small team (2-10 people)", "Many users (100+)"]
    Record both answers to `.lbwc-planning/discovery.json` as objects in `answered`, preserving each question and response, for example `{"answered":[{"question":"What are the must-have features for this project?","answer":"{answer1}"},{"question":"Who will use this?","answer":"{answer2}"}],"inferred":[],"deferred":[]}`. If either response is unavailable, add that question to `deferred` instead of discarding it.
  - **After discovery (all depths):** Call:
    ```
    bash /tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/bootstrap/bootstrap-requirements.sh .lbwc-planning/REQUIREMENTS.md .lbwc-planning/discovery.json .lbwc-planning/domain-research.md
    ```

- **B3 (ROADMAP.md)**: Suggest 3-5 phases from requirements. If `.lbwc-planning/codebase/META.md` exists, read PATTERNS.md, ARCHITECTURE.md, and CONCERNS.md (whichever exist) from `.lbwc-planning/codebase/`. Each phase needs a name, goal, mapped reqs, and success criteria. Write phases JSON to temp file, then call:
  ```
  bash /tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/bootstrap/bootstrap-roadmap.sh .lbwc-planning/ROADMAP.md "$PROJECT_NAME" /tmp/lbwc-phases.json
  ```
  Script handles ROADMAP.md generation and phase directory creation.
- **B4 (STATE.md)**: Extract project name, milestone name, and phase count from earlier steps. Call:
  ```
  bash /tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/bootstrap/bootstrap-state.sh .lbwc-planning/STATE.md "$PROJECT_NAME" "$MILESTONE_NAME" "$PHASE_COUNT"
  ```
  Script handles today's date, Phase 1 status, empty decisions, and 0% progress.
- **B5 (Brownfield summary)**: If BROWNFIELD=true AND there is no codebase/, count files by ext, check tests/CI/Docker/monorepo, and add a Codebase Profile to STATE.md.
- **B6 (CLAUDE.md)**: Extract project name and core value from PROJECT.md. If root CLAUDE.md exists, pass it as EXISTING_PATH for section preservation. Call:
  ```
  bash /tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/bootstrap/bootstrap-claude.sh CLAUDE.md "$PROJECT_NAME" "$CORE_VALUE" [CLAUDE.md]
  ```
  Script handles new file generation (heading + core value + LBWC sections). For existing files, it refreshes only exact canonical LBWC-owned sections already emitted by LBWC. It preserves the user's title/intro/arbitrary headings verbatim. It adds `## Code Intelligence` unless a Code Intelligence heading/guidance already exists anywhere in the file. If no CLAUDE.md exists, omit the fourth argument. Max 200 lines.
- **B7 (Planning commit boundary, conditional)**: Run:
   ```bash
  PG_SCRIPT="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
   if [ -f "$PG_SCRIPT" ]; then
     bash "$PG_SCRIPT" commit-boundary "bootstrap project files" .lbwc-planning/config.json
   else
     echo "⚠ LBWC: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
   fi
   ```
   If `.lbwc-planning/` or `CLAUDE.md` changed, `planning_tracking=commit` commits them. Other modes no-op.
- **B8 (Transition)**: Display "Bootstrap complete. Transitioning to scoping..." Re-evaluate state, route to next match.

## Helper Scripts

The sections above call these helpers, and each one lives under `scripts/`.

- `scripts/bootstrap/bootstrap-claude.sh`
- `scripts/bootstrap/bootstrap-project.sh`
- `scripts/bootstrap/bootstrap-requirements.sh`
- `scripts/bootstrap/bootstrap-roadmap.sh`
- `scripts/bootstrap/bootstrap-state.sh`
- `scripts/extract-skill-follow-up-files.sh`
- `scripts/planning-git.sh`
