---
category: lifecycle
disable-model-invocation: true
description: Set up environment, scaffold .lbwc-planning, detect project context, and bootstrap project-defining files.
argument-hint: "none"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Agent, LSP, Workflow
---

# LBWC Init

<!-- Steps 0-4 establish the environment before project discovery. -->
<!-- Steps 5-8 use discovery and user input to define the project. -->

## Shared interaction contract

@${CLAUDE_PLUGIN_ROOT}/references/ask-user-question.md

## Init interaction boundary

For bounded bootstrap, configuration, and setup choices, use structured @${CLAUDE_PLUGIN_ROOT}/references/ask-user-question.md prompts.
For project names, requirements, phases, and field corrections, use intentional freeform input without options.
Use freeform input for other user-authored content with many possible answers.
If `Other` or `Let me explain...` signals freeform intent, follow the shared contract.
Ask in plain text and wait for the response.
Process the response before you resume structured prompts.
Resume structured prompts only if another bounded decision remains.

## Context

Store the working directory as `{PROJECT_ROOT}`.

```bash
!`pwd`
```

Resolve the plugin root with this self-contained directive.
Shell variables do not survive across directives.

```bash
!`SESSION_KEY="${CLAUDE_SESSION_ID:-default}"; L="/tmp/.lbwc-plugin-root-link-${SESSION_KEY}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "LBWC: plugin root unavailable. Restart this session to recreate $L." >&2; exit 1; }; LINK=$(bash "$R" --require-script indexer-sync.sh) || exit 1; printf 'Plugin root: %s\n' "$LINK"`
```

Store the returned `Plugin root` value as `{LINK}` and `{plugin-root}` for all later helper calls.
Never guess a plugin path or replace a missing helper with inline code.
When a step references a script, template, command, or reference file, replace `{plugin-root}` with the stored value.

Read the existing state.

```bash
!`ls -la .lbwc-planning 2>/dev/null || echo "No .lbwc-planning directory"`
```

Find project files.

```bash
!`ls package.json pyproject.toml Cargo.toml go.mod Gemfile build.gradle pom.xml mix.exs 2>/dev/null || echo "No detected project files"`
```

Find global and project skills.

```bash
!`if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then _cd="$CLAUDE_CONFIG_DIR"; elif [ -d "$HOME/.config/claude-code" ]; then _cd="$HOME/.config/claude-code"; else _cd="$HOME/.claude"; fi; ls "$_cd/skills/" 2>/dev/null || echo "No global skills"`
```

```bash
!`ls .claude/skills/ 2>/dev/null || echo "No project skills"`
```

## Index freshness gate

Before environment setup, scaffolding, or any bootstrap write, run this exact command.

```bash
bash "{LINK}/scripts/indexer-sync.sh" --project-root "{PROJECT_ROOT}"
```

If the helper exits non-zero, stop before the Guard.

## Workflow capability gate

The Architect in Step 7c is the only agent that this command spawns.
Step 7c follows the fail-closed sequence in Step 1 and the additional refresh in Step 1.8.
Step 1 creates `.lbwc-planning/` and runs `lbwc-model refresh .lbwc-planning` before later bootstrap writes.
The refresh saves workflow availability as `.workflow` in `.lbwc-planning/claude-capabilities.json`.
Step 7c reads that catalog before it offers or resolves `workflow`.
If the refresh fails, Step 1 stops the command.
Thus, Step 7c starts with `.lbwc-planning/` and a capability catalog.
The Guard stops only when `.lbwc-planning/config.json` already exists.
A partial `.lbwc-planning/` scaffold can exist at command start, but Step 1 completes it before any spawn.

The default configuration never enters the `ask` branch in Step 7c.
Step 1 copies `config/settings.json` into `.lbwc-planning/config.json`.
That source sets `agent_execution_mode: "ask"` and `workflow_execution.enabled: false`.
Step 0 of `workflow-spawn-protocol.md` asks only when `workflow_execution.enabled` is also `true`.
Otherwise, it keeps `RESOLVED_BACKEND=in_process` without a prompt.
The `ask` branch of a fresh bootstrap offers `Workflow run` only if an earlier change enables `workflow_execution.enabled`.
That change can come from `/lbwc:config` or a non-default settings source before Step 7c.

## Guard

1. If .lbwc-planning/config.json exists, stop and display "LBWC is already initialized. Use /lbwc:config to modify settings or /lbwc:vibe to start building."
2. Run `command -v jq` via Bash. If jq is missing, stop and display "LBWC requires jq. Install: macOS `brew install jq`, Linux `apt install jq`, Manual: <https://jqlang.github.io/jq/download/>. Then re-run /lbwc:init." Do not proceed without jq.
3. Look for existing source files and stop at the first match.
   - For a git repository, run `git ls-files --error-unmatch . 2>/dev/null | head -5`. Any output means BROWNFIELD=true.
   - Without git, use Glob `**/*.*` excluding `.lbwc-planning/`, `.claude/`, `node_modules/`, `.git/`. Any match means BROWNFIELD=true.
   - Count all file types, including shell, configuration, markdown, C++, Rust, and CSS.

## Steps

Agent Teams remain available but default to disabled.
The command `/lbwc:team` owns explicit consent and the restart flow for Agent Teams.

### Step 0. Environment setup (settings.json)

Complete Step 0, including the `settings.json` write, before Step 1.
Ask bounded environment and setup questions, then wait for answers.
Write `settings.json` before you create scaffold files.
For native `Other` or freeform setup input, follow the shared interaction contract.

Resolve the configuration directory in this order.
Use the environment variable `CLAUDE_CONFIG_DIR` if it exists, even when its directory does not exist yet.
Otherwise, use `~/.config/claude-code` if that directory exists.
If neither applies, use `~/.claude`.
Store the result as `CLAUDE_DIR` and use it for all configuration paths in this command.

Read `CLAUDE_DIR/settings.json` and create `{}` if the file is missing.

For Step 0a, detect routing after the planning directory exists.
Run `bash "{plugin-root}/scripts/lbwc-model" --json refresh .lbwc-planning`.
Until the directory exists, defer the routing refresh to Step 1.8.
Do not enable experimental source teams or create static model settings.

For Step 0b, read `statusLine`.
The value can be a string or an object with a `command` field.

| State | Condition | Action |
| ------- | ----------- | -------- |
| HAS_LBWC | Value contains `lbwc-statusline` | Display "✓ Statusline: installed", skip to 0c |
| HAS_OTHER | Non-empty, no `lbwc-statusline` | AskUserQuestion (mention replacement) |
| EMPTY | Missing/null/empty | AskUserQuestion |

Use this AskUserQuestion text.
"○ LBWC includes a custom status line showing phase progress, context usage, cost, duration, and more. It updates after every response. Install it?"
If HAS_OTHER, explain that installation replaces the existing statusline.

If the user approves, set `statusLine` to this object.

```json
{"type": "command", "command": "bash -c 'for _d in \"${CLAUDE_CONFIG_DIR:-}\" \"$HOME/.config/claude-code\" \"$HOME/.claude\"\ndo\n  [ -z \"$_d\" ] && continue\n  f=$(ls -1 \"$_d\"/plugins/cache/lbwc-marketplace/lbwc/*/scripts/lbwc-statusline.sh 2>/dev/null | sort -V | tail -1 || true)\n  [ -f \"$f\" ] && exec bash \"$f\"\ndone'"}
```

Use object format with `type`+`command`.
A plain string fails without an error.
If the user declines, display "○ Skipped. Run /lbwc:config to install it later."

For Step 0c, write settings.json once if it changed.
Display this summary.

```text
Environment setup complete:
  {✓ or ○} Statusline {add "(restart to activate)" if newly installed}
  ○ Routing refresh deferred until planning scaffold exists
```

### Step 0.5. External plan redirect

Before scaffolding, look for `.planning/` or an explicit external plan path in the invocation.
If neither exists, continue without a prompt.

If an external plan exists, ask one bounded choice with `Import external plan`, `Start fresh initialization`, or `Cancel`.

- For `Import external plan`, display `Run /lbwc:import .planning` or the explicit source path. Stop before creating `.lbwc-planning`.
- For `Start fresh initialization`, continue to Step 1. Do not read, copy, index, or modify the external source.
- For `Cancel`, leave settings and project artifacts unchanged, then stop.

`/lbwc:import` is the only import authority.
Init never copies `.planning`, creates a GSD archive, or generates an import index.
It never infers GSD state or promotes imported artifacts.

### Step 1. Scaffold directory

Read each template from `{plugin-root}/templates/` and write it to .lbwc-planning/.

| Target | Source |
| -------- | -------- |
| .lbwc-planning/PROJECT.md | `{plugin-root}/templates/PROJECT.md` |
| .lbwc-planning/REQUIREMENTS.md | `{plugin-root}/templates/REQUIREMENTS.md` |
| .lbwc-planning/ROADMAP.md | `{plugin-root}/templates/ROADMAP.md` |
| .lbwc-planning/STATE.md | `{plugin-root}/templates/STATE.md` |

Create `.lbwc-planning/phases/`.
Then initialize configuration and detected routing as one fail-closed sequence.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/lbwc-config.sh" init .lbwc-planning || exit 1
if ! bash "${CLAUDE_PLUGIN_ROOT}/scripts/lbwc-model" refresh .lbwc-planning; then
  printf '%s\n' 'LBWC model catalog and routing refresh failed.' >&2
  exit 1
fi
```

Do not hand-write routing fields.
If configuration fails, stop before the model refresh.
If the model refresh fails, keep the initialized configuration for explicit recovery and stop all later bootstrap writes.

Ask this single-select AskUserQuestion.

- "How should LBWC planning artifacts be tracked in git?"
  - `manual` (default). Do not auto-ignore the whole `.lbwc-planning/` directory or auto-commit planning files.
  - `ignore`. Keep the whole `.lbwc-planning/` directory ignored in root `.gitignore`.
  - `commit`. Track `.lbwc-planning/` + `CLAUDE.md` at helper-backed planning boundaries, including bootstrap, planning checkpoints, todo adds, and archive.

Ask this single-select AskUserQuestion.

- "When should LBWC push commits?"
  - `never` (default)
  - `after_phase` (push once after a phase completes)
  - `always` (push after each commit when upstream exists)

Write the selected values to `.lbwc-planning/config.json`.

```bash
jq '.planning_tracking = "'"$PLANNING_TRACKING"'" | .auto_push = "'"$AUTO_PUSH"'"' .lbwc-planning/config.json > .lbwc-planning/config.json.tmp && mv .lbwc-planning/config.json.tmp .lbwc-planning/config.json
```

Then align git ignore behavior with the configuration.

```bash
PG_SCRIPT="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
if [ -f "$PG_SCRIPT" ]; then
  bash "$PG_SCRIPT" sync-ignore .lbwc-planning/config.json
else
  echo "⚠ LBWC: planning-git.sh unavailable. Skipping .gitignore sync." >&2
fi
```

This applies root `.gitignore` behavior for the selected mode.
It keeps `.lbwc-planning/.gitignore` current for transient runtime files in every tracking mode.

### Step 1.5. Install git hooks

1. Run `git rev-parse --git-dir`. If the directory is not a git repository, display "○ Git hooks skipped (not a git repository)" and skip.
2. Run `bash "{plugin-root}/scripts/install-hooks.sh"` and choose the display text from its output.
   - If the output contains "Installed", display `✓ Git hooks installed (pre-push)`.
   - If the output contains "already installed", display `✓ Git hooks (already installed)`.
   - If the output contains "Updated" or "Upgraded", display `✓ Git hooks updated (pre-push)`.

### Step 1.8. Detect and initialize routing profiles

Run `bash "{plugin-root}/scripts/lbwc-model" --json refresh .lbwc-planning`.
Then run `bash "{plugin-root}/scripts/lbwc-model" --json show .lbwc-planning`.
These helpers detect the current Claude catalog and install valid built-in routing profiles.
Do not read or create static model, price, alias, reasoning, or matrix files.

Show the detected selectors and the built-in `quality`, `balanced`, and `budget` profiles.
Ask one bounded question that offers the recommended active profile, another detected built-in profile, or deferred model setup.
Claude Code supplies native Other.
Accept Other only when it exactly names a profile that `show` returned.

When the user selects a profile, run `lbwc-model activate .lbwc-planning <profile>` and `lbwc-model validate .lbwc-planning`.
On failure, preserve the prior active profile and stop with the helper error.
If the user defers setup, leave the default installed profile active.
Configure custom profiles later through `/lbwc:config` or `/lbwc:profile`.
Never hand-write them during init.

### Step 2. Brownfield detection and discovery

For Step 2a, if BROWNFIELD=true, gather a codebase profile.

- Count source files by extension with Glob. Exclude .lbwc-planning/, node_modules/, .git/, vendor/, dist/, build/, target/, .next/, **pycache**/, .venv/, coverage/.
- Store SOURCE_FILE_COUNT and look for test files, CI/CD, Docker, and monorepo indicators.
- Add Codebase Profile to STATE.md.

For Step 2b, run `bash "{plugin-root}/scripts/detect-stack.sh" "$(pwd)"`.
Save the full JSON and display `✓ Stack: {comma-separated detected_stack items}`.

For Step 2.5, set up language servers and Claude plugins.
Run `bash "{plugin-root}/scripts/resolve-lsp.sh"` with the `detected_stack` JSON array from Step 2b and `CLAUDE_DIR/settings.json` path.
Capture the JSON output.

If `env_needed=false` AND all plugins have `plugin_enabled=true`, display `✓ LSP: already configured` and skip to 2c.
Otherwise, display the detected languages and recommended LSP plugins, then follow these substeps.

For Step 2.5a, if `env_needed=true`, ask about the environment flag.

- Use AskUserQuestion with "○ LSP Tools\n\nEnable LSP tools for Claude Code? This adds ENABLE_LSP_TOOL=1 to settings.json,\ngiving Claude access to goToDefinition, findReferences, and other code navigation tools."
  - If the user approves, set `env.ENABLE_LSP_TOOL` to `"1"` in `CLAUDE_DIR/settings.json`. Use the write pattern from Step 0c.
  - If the user declines, display "○ LSP env flag skipped".

For Step 2.5b, check each plugin where `binary_installed=false`.

- If `install_cmd` is not null, use AskUserQuestion with "Install {description} language server?\nCommand: `{install_cmd}`".
  - If the user approves, run the command via Bash.
  - If the user declines, display "○ {description}: skipped".
- If `install_cmd` is null and only install_url exists, display "○ {description}: manual install: {install_url}".

For Step 2.5c, if any plugins have `plugin_enabled=false`, inspect the marketplace catalog.

- Check the catalog with `unset CLAUDECODE && claude plugin marketplace list 2>&1 | grep -q "{org}"`. Use `org` from the first pending plugin.
- If the catalog is missing, use AskUserQuestion with "LSP plugins are published on the `{org}` marketplace catalog. Add it?"
  - If the user approves, run `unset CLAUDECODE && claude plugin marketplace add {org} 2>&1`.
  - If the user declines or the command fails, display "○ Marketplace catalog not available: skipping plugin installs" and skip 2.5d.

For Step 2.5d, ask about each plugin where `plugin_enabled=false`.

- Use AskUserQuestion with "Install Claude LSP plugins for: {comma-separated descriptions}?"
  - If the user approves, run `unset CLAUDECODE && claude plugin marketplace update {org} 2>&1` once.
  - Then, for each approved plugin, run `unset CLAUDECODE && claude plugin install {plugin} 2>&1`.
  - If the user declines, display "○ LSP plugins: skipped".

Display `✓ LSP: {N} language server(s) configured` or `○ LSP: skipped`.
If settings.json changes or plugin installation occurred, display `(restart Claude Code to activate LSP)`.

For Step 2c, adapt codebase mapping to the project.

- If BROWNFIELD=false, skip mapping and display `○ Greenfield: skipping codebase mapping`.
- If SOURCE_FILE_COUNT < 200, read `{plugin-root}/commands/map.md` and follow it inline.
- If SOURCE_FILE_COUNT >= 200, run mapping inline and display `◆ Codebase mapping started ({SOURCE_FILE_COUNT} files)`.

Never run mapping in the background.
Complete mapping before Step 3.

### Step 3. Convergence through stack updates and search

For Step 3a, if this is greenfield, proceed immediately.
Otherwise, make sure that mapping completed and display `✓ Codebase mapped ({document-count} documents)`.

For Step 3b, if `.lbwc-planning/codebase/STACK.md` exists, read it.
Merge additional stack components into detected_stack[].

For Step 3b2, if `.lbwc-planning/codebase/PATTERNS.md` exists, detect conventions.

- Read PATTERNS.md, ARCHITECTURE.md, STACK.md, CONCERNS.md.
- Extract conventions per `{plugin-root}/commands/teach.md` (Step R2).
- Write `.lbwc-planning/conventions.json` and display `✓ {count} conventions auto-detected from codebase`.

If this is greenfield, write `{"conventions": []}` and display `○ Conventions: none yet (add with /lbwc:teach)`.

For Step 3c, search the registry in parallel.
If npx is missing or the skills CLI fails, skip the search.
Otherwise, run `npx skills find "<stack-item>"` for all detected_stack items through concurrent Bash calls.
Deduplicate results against installed skills.
If detected_stack is empty, search by project type.
Display results with the `(registry)` tag.

For Step 3d, combine curated results from 2b and registry results from 3c in one AskUserQuestion multiSelect.
Tag each result `(curated)` or `(registry)`.
Use at most four visible choices, including `Skip`.
If more than three skills qualify, show the top three plus `Skip`.
Point broader discovery to `/lbwc:skills`.
Install selected skills into the current project with `npx skills add <skill> -y`.

### Step 3.5. Generate bootstrap CLAUDE.md

LBWC needs its rules and state sections in a CLAUDE.md file.
`/lbwc:vibe` regenerates that file later with project content.

Read root `CLAUDE.md` with the Read tool.

- If the file exists, preserve all user-authored content verbatim. Never overwrite the file or assume that its first heading and core-value lines belong to LBWC.
- Refresh only the exact canonical sections that LBWC already emitted, `## Active Context`, `## LBWC Rules`, and `## Plugin Isolation`.
- If the file has no Code Intelligence heading or guidance anywhere, add `## Code Intelligence`.

After refreshing existing sections, display `✓ CLAUDE.md (LBWC sections refreshed in place)`.
If the file does not exist, create a new `CLAUDE.md` through `bootstrap-claude.sh` during Step 7f.
Do not compose the file by hand here.
Do not append `## Project Conventions` or `## Commands` to `CLAUDE.md`.

### Step 4. Present summary

Display a Phase Banner, then a file checklist with ✓ for each created file.
Then show conditional lines for statusline, codebase mapping, conventions, and skills.

### Step 5. Scenario detection

After infrastructure setup, display `◆ Infrastructure complete. Defining project...`.
Use the flags from earlier steps to detect the initialization scenario.

1. For GREENFIELD, BROWNFIELD=false from the Guard. No existing codebase supplies context for inference.
2. For BROWNFIELD, BROWNFIELD=true AND `.lbwc-planning/codebase/` exists from Step 2c. The mapped codebase supplies context for inference.
3. For HYBRID, BROWNFIELD=true but `.lbwc-planning/codebase/` does not exist. Step 2c normally prevents this case. Handle it as GREENFIELD.

Check the conditions in this order.

```bash
if [ "$BROWNFIELD" = "true" ] && [ -d .lbwc-planning/codebase ]; then SCENARIO=BROWNFIELD
elif [ "$BROWNFIELD" = "true" ]; then SCENARIO=HYBRID
else SCENARIO=GREENFIELD
fi
```

Display the detected scenario.

```text
- GREENFIELD: `○ Scenario: Greenfield (new project)`
```

```text
- BROWNFIELD: `◆ Scenario: Brownfield (existing codebase detected)`
```

```text
- HYBRID: `○ Scenario: Hybrid (treating as greenfield, no mapping)`
```

Do not ask the user a question in this step.
Proceed immediately to Step 6.

### Step 6. Inference and confirmation

Run inference for the detected scenario and show the results to the user for confirmation.
Even when fields are null, show the inferred data (REQ-03).
Inference returns {name, tech_stack, architecture, purpose, features}.
Each field contains {value, source} for attribution.
A null value means that inference found no value, but the display still includes the field.

For Step 6a, if SCENARIO=GREENFIELD or SCENARIO=HYBRID, follow the greenfield branch.

- Display `○ Greenfield: no codebase context to infer`.
- Set SKIP_INFERENCE=true.
- Skip to Step 7, which asks discovery questions inline.

For Step 6b, if SCENARIO=BROWNFIELD, follow the brownfield branch.

- Run `bash "{plugin-root}/scripts/infer-project-context.sh" .lbwc-planning/codebase/ "$(pwd)"`.
- Capture the JSON output to `.lbwc-planning/inference.json` via Bash.
- Parse the JSON and display the inferred fields.

  ```text
  ◆ Inferred project context:
    Name:         {name.value} (source: {name.source})
    Tech stack:   {tech_stack.value | join(", ")} (source: {tech_stack.source})
    Architecture: {architecture.value} (source: {architecture.source})
    Purpose:      {purpose.value} (source: {purpose.source})
    Features:     {features.value | join(", ")} (source: {features.source})
  ```

- For null fields, always display `{field}: (not detected)`.

For Step 6d, confirm inference in all non-greenfield scenarios.
Use AskUserQuestion with "Does this look right?" and these choices.

- **"Yes, looks right"** → Proceed to Step 7 with inferred data as-is.
- **"Close, but needs adjustments"** → Enter correction flow (6e).
- **"Define from scratch"** → Set SKIP_INFERENCE=true and proceed to Step 7.

For Step 6e, if the user picks "Close, but needs adjustments", start the correction flow.
Display all fields as a numbered list.
Ask "Which fields would you like to correct?" as intentional freeform input without options.
Accept comma-separated field numbers, for example, 1,3,5.
Do not format the field list as a structured options array.

For each selected field, use AskUserQuestion to ask for the corrected value.
Update the inference JSON with those values.
After all corrections, display the updated summary and proceed to Step 7 with the corrected data.
Write the final confirmed or corrected data to `.lbwc-planning/inference.json` for Step 7.

### Step 7. Bootstrap execution

Generate all project-defining files from confirmed Step 6 data or discovery questions.
Keep these script argument formats.

| Script | Arguments |
| --- | --- |
| bootstrap-project.sh | `OUTPUT_PATH NAME DESCRIPTION` |
| bootstrap-requirements.sh | `OUTPUT_PATH DISCOVERY_JSON_PATH` |
| bootstrap-roadmap.sh | `OUTPUT_PATH PROJECT_NAME PHASES_JSON` |
| bootstrap-state.sh | `OUTPUT_PATH PROJECT_NAME MILESTONE_NAME PHASE_COUNT` |
| bootstrap-claude.sh | `OUTPUT_PATH PROJECT_NAME CORE_VALUE [EXISTING_PATH]` |

Use `{answered[], inferred[]}` in discovery.json.
Use `[{name, goal, requirements[], success_criteria[]}]` in phases.json.

Step 7g removes temporary discovery.json, phases.json, and inference.json files.
Display `◆ Generating project files...`.

For Step 7a, gather project data.
If SKIP_INFERENCE=true because this is greenfield or the user chose "Define from scratch", ask freeform discovery questions without options.

1. "What is your project name?"
2. "Describe your project in one sentence."
3. "What are the key requirements? (one per line)"
4. "What phases do you envision? For each, give a name and goal. (e.g., 'Auth: User login and registration')"

Store the answers for bootstrap script input.
If SKIP_INFERENCE=false, read `.lbwc-planning/inference.json` for the confirmed project context.
Extract NAME from `name.value` and DESCRIPTION from `purpose.value`.
For remaining user-authored content that inference does not cover, ask intentional freeform questions without options.

1. "What are the key requirements?" (pre-fill from inferred features if available)
2. "What phases do you envision?" (pre-fill from GSD recent_phases if available)

For Step 7b, generate PROJECT.md.

- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-project.sh" .lbwc-planning/PROJECT.md "$NAME" "$DESCRIPTION"`.
- Display `✓ PROJECT.md`.

For Step 7c, generate discovery.json and phases.json through an Architect with a command contract.
Follow step 0 of `{plugin-root}/references/workflow-spawn-protocol.md` and bind `<control-root>` to `.lbwc-planning`.
When that step enters the `ask` branch, use these literal `AskUserQuestion` fields.

- Set header to `Bootstrap execution`.
- Set question to `Where should the initial requirements and roadmap draft run? Workflow run orchestrates it through a committed background script. Native spawn keeps the current single-agent Architect spawn.`
- Use these options.
  - `Workflow run`. Draft requirements and roadmap through a committed workflow script in the background.
  - `Native spawn`. Keep the current native Architect spawn.
  - `Cancel bootstrap`. Stop before generating project-defining files.

On `Cancel bootstrap`, stop before the contract exists.
Keep the Step 1 scaffold, configuration, routing, and any completed codebase mapping.
Leave `REQUIREMENTS.md`, `ROADMAP.md`, and `STATE.md` at their unchanged template defaults.
Report that bootstrap generated no project-defining content.
Point to `/lbwc:vibe` to complete planning from those placeholders.

Build one complete brief from the Step 7a project data.
Reuse the brief across both branches below.

When `RESOLVED_BACKEND` is `in_process`, follow `{plugin-root}/references/agent-spawn-protocol.md`.
Issue a solo, read-only `architect` command contract for `initial requirements and roadmap`.
Run generic `scripts/agent-generator.sh architect` with the identical brief.
Use the same contract path and task id.
The generator routes through detected `lbwc-model` configuration.
Advance the contract to `dispatched`.
Spawn only with the emitted `model` and final `SPAWN_READY` name as `subagent_type` and `name`.

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

Render the prompt prefix through `{plugin-root}/references/skill-activation-payload.md`.
Ask the Architect to return exactly two complete JSON values in its report.
Use `{"answered": [requirement strings], "inferred": [{"text":..., "priority":"Must-have"}]}` for discovery data.
Use `[{"name":..., "goal":..., "requirements":[...], "success_criteria":[...]}]` for phases.
The Architect is read-only and returns content and evidence only.
It does not create, edit, stage, commit, or write planning files.

Apply the no-tool invariant from `references/subagent-contracts.md`.
Validate both JSON values.
Make sure that phase names are unique and that goals and success criteria contain content.
Check requirement coverage and dependency order.
Only after validation, write `.lbwc-planning/discovery.json` and `.lbwc-planning/phases.json` atomically from the main session.
If the Architect returns malformed or incomplete data, stop before Step 7d and leave existing artifacts unchanged.
Only after validation and persistence, display `◆ Spawning Architect agent...` followed by `✓ Architect agent complete`.

For Step 7d, generate REQUIREMENTS.md and ROADMAP.md.

- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-requirements.sh" .lbwc-planning/REQUIREMENTS.md .lbwc-planning/discovery.json`.
- Display `✓ REQUIREMENTS.md`.
- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-roadmap.sh" .lbwc-planning/ROADMAP.md "$NAME" .lbwc-planning/phases.json`.
- Display `✓ ROADMAP.md`.

For Step 7e, generate STATE.md.

- Use NAME or the first milestone from GSD inference as MILESTONE_NAME.
- Determine PHASE_COUNT from the phases.json length.
- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-state.sh" .lbwc-planning/STATE.md "$NAME" "$MILESTONE_NAME" "$PHASE_COUNT"`.
- Display `✓ STATE.md`.

For Step 7f, generate or update CLAUDE.md.

- Extract `CORE_VALUE` from `.lbwc-planning/PROJECT.md` (`grep -m1 '^\*\*Core value:\*\*' .lbwc-planning/PROJECT.md | sed 's/^\*\*Core value:\*\* *//'`).
- If root CLAUDE.md exists, pass it as EXISTING_PATH to preserve non-LBWC content.
- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-claude.sh" CLAUDE.md "$NAME" "$CORE_VALUE" "CLAUDE.md"`.
  - If CLAUDE.md does not exist yet, omit the last argument.
- Display `✓ CLAUDE.md`.

For Step 7g, remove temporary files.

- Remove `.lbwc-planning/discovery.json`, `.lbwc-planning/phases.json`, `.lbwc-planning/inference.json`, `.lbwc-planning/gsd-inference.json` if they exist.
- These files hold intermediate build artifacts, not project state.

For Step 7h, apply the conditional planning commit boundary.
Run this helper sequence.

  ```bash
  PG_SCRIPT="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
  if [ -f "$PG_SCRIPT" ]; then
    bash "$PG_SCRIPT" commit-boundary "bootstrap project files" .lbwc-planning/config.json
  else
    echo "⚠ LBWC: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
  fi
  ```

The helper follows these rules.

- If `planning_tracking=commit` and changes exist, stage `.lbwc-planning/` + `CLAUDE.md` and commit.
- If `planning_tracking=manual|ignore`, do nothing.
- If `auto_push=always` and the branch has an upstream, push.

### Step 8. Completion summary

The user now has project-defining files and can run `/lbwc:vibe` when ready.
Display a banner per @${CLAUDE_PLUGIN_ROOT}/references/lbwc-brand-essentials.md with the title "LBWC Initialization Complete".

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LBWC Initialization Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Display all files that this command created or updated.
Include the core project artifacts.

- `✓ .lbwc-planning/PROJECT.md`
- `✓ .lbwc-planning/REQUIREMENTS.md`
- `✓ .lbwc-planning/ROADMAP.md`
- `✓ .lbwc-planning/STATE.md`

Include configuration and instructions.

- `✓ CLAUDE.md`
- `✓ .lbwc-planning/config.json`

Include conditional artifacts only when their conditions apply.

- If planning_tracking=commit and changes existed, display `✓ Bootstrap planning artifacts committed`.
- If BROWNFIELD=true, display `✓ Codebase mapped`.

Display the next steps.

```text
➜ Next: Run /lbwc:vibe to start planning your first milestone
  Or:   Run /lbwc:status to review project state
```

## Failure and recovery

If `lbwc-model`, task-contract, or agent-generator fails, stop and show its error verbatim.
Do not substitute a static model file or role-specific generator.
Do not use a source team or unsupported Agent field.
If the Architect response fails validation, leave project-defining artifacts unchanged and report the rejected value.
Ask the user to retry or provide corrected freeform input under the shared interaction contract.

If the workflow generator fails or the guard denies the Architect `Workflow` call, leave the contract `planned`.
Leave project-defining artifacts unchanged and report the failure verbatim.
Do not fall back to `in_process`.

## Next Up

```text
➜ Next Up
  /lbwc:vibe - start planning the first milestone
  /lbwc:status - review project state
```

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/lbwc-brand-essentials.md

Use a Phase Banner with a double-line box, a File Checklist (✓), ○ for pending, and a Next Up Block.
Use no ANSI color codes.
