---
category: lifecycle
disable-model-invocation: true
description: Set up environment, scaffold .meridian, detect project context, and bootstrap project-defining files.
argument-hint: "none"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Agent, LSP, Workflow
---

# MERIDIAN Init

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


## Index freshness gate

Before environment setup, scaffolding, or any bootstrap write, run this exact command.

```bash
bash "{LINK}/scripts/indexer-sync.sh" --project-root "{PROJECT_ROOT}"
```

If the helper exits non-zero, stop before the Guard.

## Workflow capability gate

The Architect in Step 7c is the only agent that this command spawns.
Step 7c follows the fail-closed sequence in Step 1 and the additional refresh in Step 1.8.
Step 1 creates `.meridian/` and runs `meridian-model refresh .meridian` before later bootstrap writes.
The refresh saves workflow availability as `.workflow` in `.meridian/claude-capabilities.json`.
Step 7c reads that catalog before it offers or resolves `workflow`.
If the refresh fails, Step 1 stops the command.
Thus, Step 7c starts with `.meridian/` and a capability catalog.
The Guard stops only when `.meridian/config.json` already exists.
A partial `.meridian/` scaffold can exist at command start, but Step 1 completes it before any spawn.

The default configuration never enters the `ask` branch in Step 7c.
Step 1 copies `config/settings.json` into `.meridian/config.json`.
That source sets `agent_execution_mode: "ask"` and `workflow_execution.enabled: false`.
Step 0 of `workflow-spawn-protocol.md` asks only when `workflow_execution.enabled` is also `true`.
Otherwise, it keeps `RESOLVED_BACKEND=in_process` without a prompt.
The `ask` branch of a fresh bootstrap offers `Workflow run` only if an earlier change enables `workflow_execution.enabled`.
That change can come from `/meridian:config` or a non-default settings source before Step 7c.

<!-- rename-migration:start -->
## State migration

Before the Guard and any scaffold write, source the migration helper in the project root and run both functions in the same Bash call.

```bash
source "{LINK}/scripts/lib/rename-migration.sh"
meridian_migrate_environment
meridian_migrate_planning "{PROJECT_ROOT}"
```

Stop if the helper exits non-zero.
If both `.lbwc-planning/` and `.meridian/` exist, the helper prints one warning and leaves both unchanged.
Stop after that warning, do not scaffold or choose either directory.
If only the old directory exists, the helper moves it to `.meridian/` with one `mv` and prints one line.
The move keeps dotfiles and the journal archive.
If only `.meridian/` exists, or neither directory exists, the helper does nothing.
If `.meridian/config.json` exists after this check, stop and display "Meridian is already initialized. Use /meridian:config to modify settings or /meridian:transit to start building."
The environment helper reads old overrides only when the environment lacks the corresponding `MERIDIAN_*` name, and an explicitly empty new value still wins.
<!-- rename-migration:end -->

## Guard

1. If .meridian/config.json exists, stop and display "MERIDIAN is already initialized. Use /meridian:config to modify settings or /meridian:transit to start building."
2. Run `command -v jq` via Bash. If jq is missing, stop and display "MERIDIAN requires jq. Install: macOS `brew install jq`, Linux `apt install jq`, Manual: <https://jqlang.github.io/jq/download/>. Then re-run /meridian:init." Do not proceed without jq.
3. Look for existing source files and stop at the first match.
   - For a git repository, run `git ls-files --error-unmatch . 2>/dev/null | head -5`. Any output means BROWNFIELD=true.
   - Without git, use Glob `**/*.*` excluding `.meridian/`, `.claude/`, `node_modules/`, `.git/`. Any match means BROWNFIELD=true.
   - Count all file types, including shell, configuration, markdown, C++, Rust, and CSS.

## Steps

Agent Teams remain available but default to disabled.
The command `/meridian:team` owns explicit consent and the restart flow for Agent Teams.

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
Run `bash "{plugin-root}/scripts/meridian-model" --json refresh .meridian`.
Until the directory exists, defer the routing refresh to Step 1.8.
Do not enable experimental source teams or create static model settings.

For Step 0b, read `statusLine`.
The value can be a string or an object with a `command` field.

| State | Condition | Action |
| ------- | ----------- | -------- |
| HAS_MERIDIAN | Value contains `meridian-statusline` | Display "✓ Statusline: installed", skip to 0c |
| HAS_OTHER | Non-empty, no `meridian-statusline` | AskUserQuestion (mention replacement) |
| EMPTY | Missing/null/empty | AskUserQuestion |

Use this AskUserQuestion text.
"○ MERIDIAN includes a custom status line showing phase progress, context usage, cost, duration, and more. It updates after every response. Install it?"
If HAS_OTHER, explain that installation replaces the existing statusline.

Read `{plugin-root}/references/commands/init-statusline-install.md` for the approved statusline installation or its decline output.

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

If an external plan exists, Read `{plugin-root}/references/commands/init-external-plan.md` before any scaffold write.

`/meridian:import` is the only import authority.
Init never copies `.planning`, creates a GSD archive, or generates an import index.
It never infers GSD state or promotes imported artifacts.

### Step 1. Scaffold directory

Read each template from `{plugin-root}/templates/` and write it to .meridian/.

| Target | Source |
| -------- | -------- |
| .meridian/PROJECT.md | `{plugin-root}/templates/PROJECT.md` |
| .meridian/REQUIREMENTS.md | `{plugin-root}/templates/REQUIREMENTS.md` |
| .meridian/ROADMAP.md | `{plugin-root}/templates/ROADMAP.md` |
| .meridian/STATE.md | `{plugin-root}/templates/STATE.md` |

Create `.meridian/phases/`.
Then initialize configuration and detected routing as one fail-closed sequence.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/meridian-config.sh" init .meridian || exit 1
if ! bash "${CLAUDE_PLUGIN_ROOT}/scripts/meridian-model" refresh .meridian; then
  printf '%s\n' 'MERIDIAN model catalog and routing refresh failed.' >&2
  exit 1
fi
```

Do not hand-write routing fields.
If configuration fails, stop before the model refresh.
If the model refresh fails, keep the initialized configuration for explicit recovery and stop all later bootstrap writes.

Ask this single-select AskUserQuestion.

- "How should MERIDIAN planning artifacts be tracked in git?"
  - `manual` (default). Do not auto-ignore the whole `.meridian/` directory or auto-commit planning files.
  - `ignore`. Keep the whole `.meridian/` directory ignored in root `.gitignore`.
  - `commit`. Track `.meridian/` + `CLAUDE.md` at helper-backed planning boundaries, including bootstrap, planning checkpoints, todo adds, and archive.

Ask this single-select AskUserQuestion.

- "When should MERIDIAN push commits?"
  - `never` (default)
  - `after_phase` (push once after a phase completes)
  - `always` (push after each commit when upstream exists)

Write the selected values to `.meridian/config.json`.

```bash
jq '.planning_tracking = "'"$PLANNING_TRACKING"'" | .auto_push = "'"$AUTO_PUSH"'"' .meridian/config.json > .meridian/config.json.tmp && mv .meridian/config.json.tmp .meridian/config.json
```

Then align git ignore behavior with the configuration.

```bash
PG_SCRIPT="{plugin-root}/scripts/planning-git.sh"
if [ -f "$PG_SCRIPT" ]; then
  bash "$PG_SCRIPT" sync-ignore .meridian/config.json
else
  echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping .gitignore sync." >&2
fi
```

This applies root `.gitignore` behavior for the selected mode.
It keeps `.meridian/.gitignore` current for transient runtime files in every tracking mode.

### Step 1.5. Install git hooks

At Step 1.5, Read `{plugin-root}/references/commands/init-git-hooks.md` to check for a git repository and install its hooks, skipping installation only outside a git repository.

### Step 1.8. Detect and initialize routing profiles

Run `bash "{plugin-root}/scripts/meridian-model" --json refresh .meridian`.
Then run `bash "{plugin-root}/scripts/meridian-model" --json show .meridian`.
These helpers detect the current Claude catalog and install valid built-in routing profiles.
Do not read or create static model, price, alias, reasoning, or matrix files.

Show the detected selectors and the built-in `quality`, `balanced`, and `budget` profiles.
Ask one bounded question that offers the recommended active profile, another detected built-in profile, or deferred model setup.
Claude Code supplies native Other.
Accept Other only when it exactly names a profile that `show` returned.

When the user selects a profile, run `meridian-model activate .meridian <profile>` and `meridian-model validate .meridian`.
On failure, preserve the prior active profile and stop with the helper error.
If the user defers setup, leave the default installed profile active.
Configure custom profiles later through `/meridian:config` or `/meridian:profile`.
Never hand-write them during init.

### Step 2. Brownfield detection and discovery

For Step 2a with `BROWNFIELD=true`, Read `{plugin-root}/references/commands/init-brownfield-profile.md` to gather the codebase profile.

For Step 2b, run `bash "{plugin-root}/scripts/detect-stack.sh" "$(pwd)"`.
Save the full JSON and display `✓ Stack: {comma-separated detected_stack items}`.

For Step 2.5, set up language servers and Claude plugins.
Run `bash "{plugin-root}/scripts/resolve-lsp.sh"` with the `detected_stack` JSON array from Step 2b and `CLAUDE_DIR/settings.json` path.
Capture the JSON output.

If `env_needed=false` AND all plugins have `plugin_enabled=true`, display `✓ LSP: already configured` and skip to 2c.
Otherwise, Read `{plugin-root}/references/commands/init-lsp-setup.md` for the conditional environment, language-server, and plugin setup choices.

For Step 2c, Read `{plugin-root}/references/commands/init-codebase-mapping.md` to map brownfield projects inline or display the greenfield skip before Step 3.

### Step 3. Convergence through stack updates and search

For Step 3a, if this is greenfield, proceed immediately.
Otherwise, make sure that mapping completed and display `✓ Codebase mapped ({document-count} documents)`.

When stack or pattern mapping files exist, Read `{plugin-root}/references/commands/init-stack-conventions.md` for Steps 3b and 3b2.
If this is greenfield, write `{"conventions": []}` and display `○ Conventions: none yet (add with /meridian:teach)`.

For Steps 3c and 3d, Read `{plugin-root}/references/commands/init-skill-search.md` and follow its registry-search or CLI-unavailable path.

### Step 3.5. Generate bootstrap CLAUDE.md

MERIDIAN needs its rules and state sections in a CLAUDE.md file.
`/meridian:transit` regenerates that file later with project content.

Read root `CLAUDE.md` with the Read tool.

When root CLAUDE.md exists, Read `{plugin-root}/references/commands/init-existing-claude.md` before refreshing its owned sections.
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
2. For BROWNFIELD, BROWNFIELD=true AND `.meridian/codebase/` exists from Step 2c. The mapped codebase supplies context for inference.
3. For HYBRID, BROWNFIELD=true but `.meridian/codebase/` does not exist. Step 2c normally prevents this case. Handle it as GREENFIELD.

Check the conditions in this order.

```bash
if [ "$BROWNFIELD" = "true" ] && [ -d .meridian/codebase ]; then SCENARIO=BROWNFIELD
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

For `SCENARIO=BROWNFIELD`, Read `{plugin-root}/references/commands/init-brownfield-inference.md` for inference, confirmation, and any field corrections before Step 7.

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

For Step 7a with `SKIP_INFERENCE=true`, Read `{plugin-root}/references/commands/init-discovery-input.md` for freeform discovery before generating PROJECT.md.
For Step 7a with `SKIP_INFERENCE=false`, Read `{plugin-root}/references/commands/init-inferred-input.md` for confirmed context and remaining freeform questions before generating PROJECT.md.

For Step 7b, generate PROJECT.md.

- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-project.sh" .meridian/PROJECT.md "$NAME" "$DESCRIPTION"`.
- Display `✓ PROJECT.md`.

For Step 7c, generate discovery.json and phases.json through an Architect with a command contract.
Follow step 0 of `{plugin-root}/references/workflow-spawn-protocol.md` and bind `<control-root>` to `.meridian`.
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
Point to `/meridian:transit` to complete planning from those placeholders.

Build one complete brief from the Step 7a project data.
Reuse the brief across both branches below.

When `RESOLVED_BACKEND=in_process`, Read `{plugin-root}/references/commands/init-native-architect.md` before issuing the Architect contract and spawning.

When `RESOLVED_BACKEND=workflow`, Read `{plugin-root}/references/commands/init-workflow-architect.md` and await its terminal Architect report before validation or persistence.

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
Only after validation, write `.meridian/discovery.json` and `.meridian/phases.json` atomically from the main session.
If the Architect returns malformed or incomplete data, stop before Step 7d and leave existing artifacts unchanged.
Only after validation and persistence, display `◆ Spawning Architect agent...` followed by `✓ Architect agent complete`.

For Step 7d, generate REQUIREMENTS.md and ROADMAP.md.

- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-requirements.sh" .meridian/REQUIREMENTS.md .meridian/discovery.json`.
- Display `✓ REQUIREMENTS.md`.
- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-roadmap.sh" .meridian/ROADMAP.md "$NAME" .meridian/phases.json`.
- Display `✓ ROADMAP.md`.

For Step 7e, generate STATE.md.

- Use NAME or the first milestone from GSD inference as MILESTONE_NAME.
- Determine PHASE_COUNT from the phases.json length.
- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-state.sh" .meridian/STATE.md "$NAME" "$MILESTONE_NAME" "$PHASE_COUNT"`.
- Display `✓ STATE.md`.

For Step 7f, generate or update CLAUDE.md.

- Extract `CORE_VALUE` from `.meridian/PROJECT.md` (`grep -m1 '^\*\*Core value:\*\*' .meridian/PROJECT.md | sed 's/^\*\*Core value:\*\* *//'`).
- If root CLAUDE.md exists, pass it as EXISTING_PATH to preserve non-MERIDIAN content.
- Run `bash "{plugin-root}/scripts/bootstrap/bootstrap-claude.sh" CLAUDE.md "$NAME" "$CORE_VALUE" "CLAUDE.md"`.
  - If CLAUDE.md does not exist yet, omit the last argument.
- Display `✓ CLAUDE.md`.

For Step 7g, remove temporary files.

- Remove `.meridian/discovery.json`, `.meridian/phases.json`, `.meridian/inference.json`, `.meridian/gsd-inference.json` if they exist.
- These files hold intermediate build artifacts, not project state.

For Step 7h, apply the conditional planning commit boundary.
Run this helper sequence.

  ```bash
  PG_SCRIPT="{plugin-root}/scripts/planning-git.sh"
  if [ -f "$PG_SCRIPT" ]; then
    bash "$PG_SCRIPT" commit-boundary "bootstrap project files" .meridian/config.json
  else
    echo "⚠ MERIDIAN: planning-git.sh unavailable. Skipping planning git boundary commit." >&2
  fi
  ```

The helper follows these rules.

- If `planning_tracking=commit` and changes exist, stage `.meridian/` + `CLAUDE.md` and commit.
- If `planning_tracking=manual|ignore`, do nothing.
- If `auto_push=always` and the branch has an upstream, push.

### Step 8. Completion summary

After bootstrap succeeds, Read `{plugin-root}/references/commands/init-completion.md` and display its success summary and conditional artifact lines.

## Failure and recovery

If `meridian-model`, task-contract, or agent-generator fails, stop and show its error verbatim.
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
  /meridian:transit - start planning the first milestone
  /meridian:status - review project state
```

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md

Use a Phase Banner with a double-line box, a File Checklist (✓), ○ for pending, and a Next Up Block.
Use no ANSI color codes.

## Context

Store the working directory as `{PROJECT_ROOT}`.

```bash
!`pwd`
```

Resolve the plugin root with this self-contained directive.
Shell variables do not survive across directives.

```bash
!`SESSION_KEY="${CLAUDE_SESSION_ID:-root-$(printf "%s\n" "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)" | shasum -a 256 | cut -c1-64)}"; [ "$SESSION_KEY" != root- ] || { echo "MERIDIAN: plugin root hash unavailable" >&2; exit 1; }; L="/tmp/.meridian-plugin-root-link-${SESSION_KEY}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "MERIDIAN: plugin root unavailable. Restart this session to recreate $L." >&2; exit 1; }; LINK=$(bash "$R" --require-script indexer-sync.sh) || exit 1; printf 'Plugin root: %s\n' "$LINK"`
```

Store the returned `Plugin root` value as `{LINK}` and `{plugin-root}` for all later helper calls.
Never guess a plugin path or replace a missing helper with inline code.
When a step references a script, template, command, or reference file, replace `{plugin-root}` with the stored value.

Read the existing state.

```bash
!`ls -la .meridian 2>/dev/null || echo "No .meridian directory"`
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

## Feedback card

As the last output step, follow the Feedback card input section in `${CLAUDE_PLUGIN_ROOT}/references/handoff-schemas.md`.
