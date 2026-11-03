---
category: supporting
model: sonnet
disable-model-invocation: true
description: View and modify LBWC configuration including execution mode, effort profile, verification tier, and skill-hook wiring.
argument-hint: "[setting value]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# LBWC Config $ARGUMENTS

## Context

Plugin root:

```bash
!`L="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "LBWC: plugin root unavailable. Restart this session to recreate $L." >&2; exit 1; }; bash "$R" >/dev/null || exit 1; echo "$L"`
```

Store the plugin root path output above as `{plugin-root}` for use in script and config lookups below. Replace `{plugin-root}` with the literal `Plugin root` value from Context whenever a step below references a script or file in the installed plugin.

@${CLAUDE_PLUGIN_ROOT}/references/ask-user-question.md

Config:

```bash
!`cat .lbwc-planning/config.json 2>/dev/null || echo "No config found -- run /lbwc:init first"`
```

## Guard

If no .lbwc-planning/ dir exists, STOP with "Run /lbwc:init first." (check `.lbwc-planning/config.json`)

## Behavior

Agent Teams is process-level Claude Code configuration. `/lbwc:team` checks it through `lbwc-config.sh agent-teams-check`, which reads Claude Code `settings.json`. Enabling requires a main-session confirmation, then `lbwc-config.sh agent-teams-enable --approved`. The command must stop with restart guidance because changing settings cannot enable the current process.

Every ordinary setting mutation runs `bash "{plugin-root}/scripts/lbwc-config.sh" set .lbwc-planning <setting> <value-json>`, followed by `lbwc-config.sh validate`. The only routing setting exposed here is `routing.active_profile`, which mutates through `lbwc-model activate`, not through direct JSON writes.

### Step 0 (always): validate and migrate configuration

Run `bash "{plugin-root}/scripts/lbwc-config.sh" migrate .lbwc-planning`, then `bash "{plugin-root}/scripts/lbwc-config.sh" validate .lbwc-planning`. A nonzero result stops the command and leaves the invalid file for explicit repair. Do not silently replace it with defaults. Validate routing profiles separately with `bash "{plugin-root}/scripts/lbwc-model" validate .lbwc-planning`.

### No arguments (interactive configuration)

**Step 1:** Display current settings in single-line box table (setting, value, description) + skill-hook mappings.

Before any presentation, run `bash "{plugin-root}/scripts/lbwc-model" --json refresh .lbwc-planning`.

Present the detected routing state by running `bash "{plugin-root}/scripts/lbwc-model" --json show .lbwc-planning`. Render its active profile and each supported role's selector and reasoning value, plus its turn limit. Mark custom profiles as custom. Do not resolve roles through static profile files or assign cost weights.

**Step 2:** AskUserQuestion with 1 question:

- header: `Config`
- question: `What would you like to adjust?`
- options:
  - `Core settings`: Effort, autonomy, planning tracking, auto push
  - `Model profile`: Preset profile or per-agent overrides
  - `Execution mode`: In-process agents or TMUX split panes
  - `Exit`: Leave config unchanged

Store selection in variable `CONFIG_SECTION`.

Every bounded AskUserQuestion branch below follows `references/ask-user-question.md`. Accept direct option intent. Accept unambiguous visible option-by-number replies (for example `#1`, `option 2`, or `2`). Accept hybrid replies anchored to one visible option number (for example `#2 please`). Re-ask only when the reply is ambiguous or invalid for that same question. Do not add an extra visible `Other` option.

If `CONFIG_SECTION = "Exit"`:

- Display `✓ No changes made.`
- Run `bash "{plugin-root}/scripts/suggest-next.sh" config` and display.
- STOP.

**Step 2.5:** If `CONFIG_SECTION = "Core settings"`, AskUserQuestion with 1 question:

- header: `Core`
- question: `Which core setting do you want to change?`
- options:
  - `Effort`: current: {effort value}  (thorough | balanced | fast | turbo)
  - `Autonomy`: current: {autonomy value}  (cautious | standard | confident | pure-vibe)
  - `Planning tracking`: current: {tracking value}  (manual | ignore | commit)
  - `Auto push`: current: {auto_push value}  (never | after_phase | always)

Store selection in variable `SETTING_GROUP`.

Map:

- `Effort` → `SETTING=effort`
- `Autonomy` → `SETTING=autonomy`
- `Planning tracking` → `SETTING=planning_tracking`
- `Auto push` → `SETTING=auto_push`

**Step 2.6:** Ask the bounded value question for the selected core setting.

If `SETTING=effort`, AskUserQuestion with 1 question:

- header: `Effort`
- question: `Choose effort level.`
- options:
  - `thorough`: Maximum planning and verification depth
  - `balanced`: Default depth for most work
  - `fast`: Lighter planning, quicker verification
  - `turbo`: Minimal ceremony, fastest path

If `SETTING=autonomy`, AskUserQuestion with 1 question:

- header: `Autonomy`
- question: `Choose autonomy level.`
- options:
  - `cautious`: Confirm more often
  - `standard`: Default phase-by-phase flow
  - `confident`: Fewer confirmations
  - `pure-vibe`: Full auto loop through phases

If `SETTING=planning_tracking`, AskUserQuestion with 1 question:

- header: `Tracking`
- question: `How should the plugin track planning artifacts?`
- options:
  - `manual`: Leave planning files for manual git handling
  - `ignore`: Keep `.lbwc-planning/` out of git
  - `commit`: Auto-commit planning artifacts

If `SETTING=auto_push`, AskUserQuestion with 1 question:

- header: `Auto push`
- question: `When should LBWC push automatically?`
- options:
  - `never`: Never push automatically
  - `after_phase`: Push once after each phase
  - `always`: Push after every commit

Store the selected value in variable `VALUE`.

After the user chooses a core setting value, continue to Step 3 and apply it there with the same validation, write behavior, and side effects as the `/lbwc:config <setting> <value>` path below. Step 4 remains the no-args tail behavior after that shared apply step.

**Step 2.7:** If `CONFIG_SECTION = "Model profile"`, AskUserQuestion with 1 question:

- header: `Models`
- question: `How do you want to configure model behavior?`
- options:
  - `Use preset profile`: quality, balanced, or budget
  - `Configure each agent individually`: 6 per-agent model questions
  - `Model matrix`: Re-detect available models and rebuild the agent x effort matrix

Store selection in variable `PROFILE_METHOD`.

**Branching:**

- If `PROFILE_METHOD = "Use preset profile"`, call AskUserQuestion with 1 question and 3 options (`quality`, `balanced`, `budget`). Store the selected preset in `PROFILE`, then continue to Step 3 and apply it there using the `Model profile switching` logic below.
- If `PROFILE_METHOD = "Configure each agent individually"`, proceed to individual agent configuration flow (Round 1 below).
- If `PROFILE_METHOD = "Model matrix"`, run the model matrix flow below, then continue to Step 4.

**Step 2.8:** If `CONFIG_SECTION = "Execution mode"`, AskUserQuestion with 1 question:

- header: `Agent execution`
- question: `Where should LBWC run spawned agents?`
- options:
  - `In-process agents`: Preserve the current native Agent execution path
  - `TMUX split panes`: Persist the TMUX execution backend and its restrictions
  - `Cancel spawn`: Do not spawn agents for this step

Store the selection in variable `EXECUTION_MODE`.

- If `EXECUTION_MODE = "Cancel spawn"`, display `✓ No changes made.` and STOP. Cancel is terminal for the requested spawn. Do not write `in_process` and do not silently fall back to another backend.
- If `EXECUTION_MODE = "In-process agents"`, run `bash "{plugin-root}/scripts/lbwc-config.sh" set .lbwc-planning agent_execution_mode '"in_process"'`, then validate.
- If `EXECUTION_MODE = "TMUX split panes"`, run `bash "{plugin-root}/scripts/lbwc-config.sh" set .lbwc-planning tmux_execution.enabled true`, then run `bash "{plugin-root}/scripts/lbwc-config.sh" set .lbwc-planning agent_execution_mode '"tmux"'`, then validate.

The default `agent_execution_mode=ask` and `tmux_execution.enabled=false` preserve the current in-process behavior until a caller presents its execution gate. A caller that presents the gate must treat `Cancel spawn` as cancellation, not as an automatic Option 1 fallback.

**Detected model configuration:**

Run `bash "{plugin-root}/scripts/lbwc-model" --json refresh .lbwc-planning`, then `bash "{plugin-root}/scripts/lbwc-model" --json show .lbwc-planning`. The detected Claude catalog, accepted reasoning values, built-in profiles, active profile, and custom profiles in that output are authoritative. Do not read or write a static model-price, alias, matrix, or reasoning file.

- **Use preset profile:** Show only built-in profile names from the `show` result. Confirm one bounded choice, then run `lbwc-model activate .lbwc-planning <profile>`.
- **Configure each agent individually:** Read the active profile and catalog from `show` and `catalog`. Ask one bounded question at a time for each supported role. Every selector and reasoning value must appear in the detected catalog. Apply each accepted cell through `lbwc-model set .lbwc-planning <profile> <role> <selector> <reasoning-json>`.
- **Model matrix:** Copy the active profile to a user-named custom profile with `lbwc-model copy`, edit its role cells through `lbwc-model set`, validate it, then activate it. Do not create a parallel matrix schema.

Native Other text may name a detected selector or profile. Reject an unknown value with the exact validation error and keep the current profile unchanged. Every mutation must end with `lbwc-model validate .lbwc-planning` and a fresh `lbwc-model show .lbwc-planning`. On Cancel, make no model mutation and return to Step 2.7.

**Step 3:** Apply changes to config.json. This is the shared apply step for no-args core-setting changes and preset-model-profile changes. Display ✓ per changed setting with ➜. No changes: "✓ No changes made."

**Step 4 (profile drift detection).** If effort/autonomy/verification_tier changed:

- Compare against active profile's expected values
- If they mismatch, call AskUserQuestion "Settings no longer match '{profile}'. Save as new profile?" → "Save" (route to /lbwc:profile save) or "No" (set active_profile to "custom")
- Skip if no profile-tracked settings changed or already "custom"

Run `bash "{plugin-root}/scripts/suggest-next.sh" config` and display.

### With arguments: `<setting> <value>`

Validate setting + value. Update config.json. Display ✓ with ➜.

Execution settings use the same transaction and validation path as every other setting:

- `agent_execution_mode` accepts only `in_process`, `tmux`, `workflow`, or `ask`.
- `tmux_execution.<field>` updates one validated field without replacing the other fields.
- `set-json` accepts a complete `tmux_execution` object for atomic replacement. The object must contain every documented field and no unknown fields.
- `tmux_execution.enabled` is false by default and becomes true only after the user accepts the TMUX option.

If `setting=max_uat_remediation_rounds`, validate the value before writing:

```bash
CANONICAL_VALUE=$(bash "{plugin-root}/scripts/resolve-uat-remediation-round-limit.sh" --validate-input "$2" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "${CANONICAL_VALUE:-}" ]; then
  echo "⚠ Invalid max_uat_remediation_rounds '$2'. Valid values: false, 0, or a positive integer"
  exit 0
fi

jq ".max_uat_remediation_rounds = ${CANONICAL_VALUE}" .lbwc-planning/config.json > .lbwc-planning/config.json.tmp && mv .lbwc-planning/config.json.tmp .lbwc-planning/config.json
echo "✓ max_uat_remediation_rounds ➜ ${CANONICAL_VALUE}"
exit 0
```

If `setting=planning_tracking`, after writing config run:

```bash
  PG_SCRIPT="/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/planning-git.sh"
  if [ -f "$PG_SCRIPT" ]; then
    bash "$PG_SCRIPT" sync-ignore .lbwc-planning/config.json
  else
    echo "⚠ LBWC: planning-git.sh unavailable. Skipping .gitignore sync." >&2
  fi
```

This applies any mode-specific root `.gitignore` behavior and keeps `.lbwc-planning/.gitignore` current for transient runtime files in every tracking mode.

### Skill-hook wiring: `skill_hook <skill> <event> <tools>`

- `config skill_hook lint-fix PostToolUse Write|Edit`
- `config skill_hook test-runner PostToolUse Bash`
- `config skill_hook remove <skill>`

Stored in config.json `skill_hooks`:

```json
{"skill_hooks": {"lint-fix": {"event": "PostToolUse", "tools": "Write|Edit"}}}
```

### Model profile switching: `model_profile <profile>`

Run `bash "{plugin-root}/scripts/lbwc-model" activate .lbwc-planning "$PROFILE"`, then validate and show the result. The helper accepts built-in and valid custom profiles from the detected catalog. An unknown profile exits nonzero and leaves the active profile unchanged.

### Per-agent route: `model_override <role> <selector> [reasoning-json]`

Read the active profile with `lbwc-model --json show`. Validate the role, selector, and optional reasoning value against `lbwc-model --json catalog`. Apply the cell through `lbwc-model set .lbwc-planning <active-profile> <role> <selector> <reasoning-json>`, then run `lbwc-model validate`. Never write model routing fields directly with jq.

## Settings Reference

Note that `auto_commit` controls source-task commits during Execute mode, while `planning_tracking` controls planning artifact commit behavior.

| Setting | Type | Values | Default |
| ------- | ---- | ------ | ------- |
| effort | string | thorough/balanced/fast/turbo | balanced |
| autonomy | string | cautious/standard/confident/pure-vibe | standard |
| auto_commit | boolean | true/false | true |
| planning_tracking | string | manual/ignore/commit | manual |
| auto_push | string | never/after_phase/always | never |
| verification_tier | string | quick/standard/deep | standard |
| skill_suggestions | boolean | true/false | true |
| auto_install_skills | boolean | true/false | false |
| discovery_questions | boolean | true/false | true |
| discussion_mode | string | questions/assumptions/auto | questions |
| visual_format | string | unicode/ascii | unicode |
| max_tasks_per_plan | number | 1-7 | 5 |
| prefer_teams | string | always/auto/never | auto |
| agent_execution_mode | string | in_process/tmux/workflow/ask | ask |
| tmux_execution | object | strict TMUX backend and restriction object | enabled=false |
| tmux_execution.enabled | boolean | true/false | false |
| tmux_execution.session_name_prefix | string | ASCII name prefix, 1-32 characters | lbwc |
| tmux_execution.max_agents | integer | 1-4 | 3 |
| tmux_execution.attach_policy | string | orchestrator_only/visible_grid | orchestrator_only |
| tmux_execution.heartbeat_interval_seconds | integer | positive seconds | 30 |
| tmux_execution.heartbeat_stale_seconds | integer | positive seconds, can only tighten the threshold to min(3 × heartbeat_interval_seconds, configured value) | 90 effective seconds at the default interval |
| tmux_execution.comms_latency_tolerance_ms | integer | positive milliseconds | 5000 |
| tmux_execution.comms_fallback | string | bus_only/fall_back_to_in_process | bus_only |
| tmux_execution.cleanup_policy | string | kill_on_complete/keep_panes | kill_on_complete |
| tmux_execution.layout | string | main-vertical/main-horizontal/tiled/even-horizontal/even-vertical | main-vertical |
| tmux_execution.restrictions | object | four strict boolean restrictions | see defaults |
| workflow_execution | object | strict workflow backend object | enabled=false |
| workflow_execution.enabled | boolean | true/false | false |
| pipeline_research | boolean | true/false | false |
| branch_per_milestone | boolean | true/false | false |
| plain_summary | boolean | true/false | true |
| active_profile | string | profile name or "custom" | default |
| custom_profiles | object | user-defined profiles | {} |
| agent_max_turns | object | per-agent turns (number), 0/false = unlimited | scout=30, qa=20, architect=50, debugger=40, lead=50, engineers=50, test-dev=40 |
| qa_skip_agents | array | array of agent role names | ["docs"] |
| context_compiler | boolean | true/false | true |
| metrics | boolean | true/false | true |
| token_budgets | boolean | true/false, [persistence-only], validated and persisted as the token-budget flag | true |
| two_phase_completion | boolean | true/false, [persistence-only], validated and persisted as the two-phase completion flag | true |
| smart_routing | boolean | true/false, [persistence-only], validated and persisted as the smart-routing flag | true |
| validation_gates | boolean | true/false, [persistence-only], validated and persisted as the validation-gates flag | true |
| snapshot_resume | boolean | true/false, [persistence-only], validated and persisted as the snapshot/resume flag | true |
| lease_locks | boolean | true/false, [persistence-only], validated and persisted as the lease-lock flag | true |
| event_recovery | boolean | true/false, [persistence-only], validated and persisted as the event-recovery flag | true |
| worktree_isolation | string | off/on | off |
| monorepo_routing | boolean | true/false, [persistence-only], validated and persisted as the monorepo-routing flag | true |
| require_phase_discussion | boolean | true/false | false |
| auto_uat | boolean | true/false | false |
| max_uat_remediation_rounds | boolean/number | false, 0, or positive integer | false |
| rolling_summary | boolean | true/false | false |
| debug_logging | boolean | true/false | false |
| statusline_hide_limits | boolean | true/false | false |
| statusline_hide_limits_for_api_key | boolean | true/false | false |
| statusline_hide_agent_in_tmux | boolean | true/false | false |
| statusline_collapse_agent_in_tmux | boolean | true/false | false |
| caveman_style | string | none/lite/full/ultra/auto | none |
| caveman_commit | boolean | true/false | false |
| caveman_review | boolean | true/false | false |

### Internal and legacy keys

These rows describe existing readers, not new writable settings. `/config` cannot set `compaction_threshold`, `qa_commit_window_seconds`, or `hooks.post_archive` because the strict schema rejects them. The `[persistence-only]` marker means that schema validation and storage form the documented contract, not a runtime switch.

| Setting | Type | Reader and behavior | Default |
| ------- | ---- | ------------------- | ------- |
| schema_version | integer | [persistence-only], the validator checks the configuration version in `scripts/lib/lbwc-config-defaults.sh:24` and `scripts/lib/lbwc-config-validate.jq:74` | 1 |
| compaction_threshold | integer | `scripts/lib/phase-detect-environment-output.sh:40` reads a token threshold and `scripts/suggest-compact.sh:244` reads the projected-token threshold | 130000 in phase detection, unset disables the projected-token check |
| qa_commit_window_seconds | integer | `scripts/qa-gate.sh:84` accepts positive seconds for recent QA commit evidence | 7200 |
| hooks.post_archive | string | `scripts/post-archive-hook.sh:64` reads an optional script path after archive | empty string |
| routing | object | `scripts/lib/team-command-transaction-routing.sh:13` checks routing before transaction preparation | generated routing object |
| routing.active_profile | string | `scripts/runtime-snapshot.sh:74` freezes the active model routing profile | balanced |
| routing.profiles | object | `scripts/runtime-snapshot.sh:68` reads the selected profile and its role cells | generated quality, balanced and turbo profiles |
| routing.profiles.balanced.roles | object | `scripts/resolve-agent-settings.sh:83` reads balanced role cells for the workflow backend | generated role cells |
| roles | object | `scripts/lib/turn-value.sh:67` reads legacy per-role turn limits and `scripts/lib/lbwc-routing-migrate.sh:6` migrates legacy roles | empty object |
| model_profile | string | `scripts/lib/lbwc-routing-migrate.sh:11` reads the legacy profile and `scripts/lib/suggest-next-state.sh:138` checks its presence | balanced during routing migration, quality during suggest-next initialization |
| max_remediation_rounds | boolean/number | `scripts/resolve-uat-remediation-round-limit.sh:123` reads the legacy alias after the canonical key | false |
| v3_rolling_summary | boolean | `scripts/cache-context.sh:200` and `scripts/compile-context.sh:174` read the legacy alias after rolling_summary | false |
| tmux.layout | string | `scripts/tmux-agent-orchestrator.sh:70` reads the legacy layout after tmux_execution.layout | tiled |
| tmux.max_agents | integer | `scripts/tmux-agent-orchestrator.sh:70` reads the legacy agent limit after tmux_execution.max_agents | 3 |

### Debug logging

`debug_logging` defaults to `false`, which leaves hook output unchanged and creates no log file. Set it to `true` to append decision records from the dispatcher and guard scripts to `<planning dir>/.debug.log`. Each record holds a UTC timestamp, component, hook event, check name, decision, duration in milliseconds when known, and a short reason code. Shell durations use whole-second precision.

Before an append would exceed 1,048,576 bytes, the writer moves the current file to `.debug.log.1` and replaces any older archive. Concurrent writers share a rotation lock and append each line with one write. Logging failures never change hook output or decisions.

The log never holds payloads, tool input, file contents, command text, prompts, or environment values. Check names use component basenames, not full paths. The planning ignore list excludes `.debug.log*`.

### Execution Runtime Rules

- During active plan execution, identified by `.execution-state.json` status `running`, `executing`, or `active`, `STATE.md` status `active` or `executing`, or a dispatched or running task contract, the execution backend stays fixed.
- The frozen fields are `agent_execution_mode`, `tmux_execution.max_agents`, `tmux_execution.comms_fallback`, `tmux_execution.restrictions.allow_agent_git`, `effort`, and `routing.active_profile`.
- `tmux_execution.cleanup_policy` may change for the next teardown. The emergency `agent_execution_mode=in_process` override works only when the registry lists no running TMUX agents.
- The command rejects invalid or malformed configuration and keeps the saved file. Migration fills only missing execution defaults and preserves valid existing values.
- `agent_execution_mode=ask` is a persisted gate, not a fallback instruction. A rejected or cancelled spawn remains cancelled until the caller explicitly starts a different backend.

### Statusline switches

Four flags control what the LBWC statusline shows:

- **`statusline_hide_limits`**: Suppress the Quota line (L3, the 5-hour and 7-day rate limits) unconditionally. Use this if you never want to see rate limit information in the statusline.

- **`statusline_hide_limits_for_api_key`**: Suppress the Quota line (L3) only when the session uses API-key authentication instead of Claude.ai OAuth. The switch treats a non-empty `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` environment variable as API-key authentication. Useful when you find the usage display redundant in API-key sessions. Has no effect when `statusline_hide_limits` is also `true` (the broader flag takes precedence).

- **`statusline_hide_agent_in_tmux`**: Suppress the Flow line (L1, the phase, task, pair, and trio progress) while inside a tmux session. Has no effect outside tmux or when no build is running. Use this to reduce statusline noise in tmux-based workflows.

- **`statusline_collapse_agent_in_tmux`**: Collapse the full 4-line statusline into a single summary line in agent/worktree panes (not the orchestrator). Only applies inside tmux, only when running in a git worktree. Has no effect outside tmux or in the main repo pane.

### agent_max_turns

Controls the generated agent definition's internal turn limit. `scripts/resolve-agent-settings.sh` resolves and validates the value before generation. The Agent call itself receives no unsupported turn-limit field.

The resolver picks the turn limit from the first source that has a value:

1. The CLI `--max-turns` flag.
2. `agent_max_turns.<role>`, used as an absolute number that effort does not scale.
3. `roles.<role>.max_turns`, scaled by the active effort.
4. The role default in `templates/agent-roles/defaults.json`, scaled by the active effort.

The key `dev` is an alias for the four engineer roles `coding-dijkstra`, `python-engineer`, `web-engineer`, and `test-dev`. An exact role name always wins over `dev`, so `agent_max_turns.python-engineer` overrides `agent_max_turns.dev` for that role. An object value picks the number for the active effort. When the object has no entry for the active effort, the resolver moves on to the next source.

A JSON `null` means not set, so `"lead": null` falls through to the next source. Only `false` and `0` mean no limit.

Set a per-agent value to `false` or `0` for no generated turn limit:

```json
{
  "agent_max_turns": {
    "dev": false,
    "debugger": 0
  }
}
```

You can also provide per-effort overrides using an object instead of a number:

```json
{
  "agent_max_turns": {
    "dev": { "thorough": 120, "balanced": 75, "fast": 50, "turbo": false }
  }
}
```

### max_uat_remediation_rounds

Controls only the UAT remediation auto-continuation loop after re-verification finds issues. It does **not** apply to QA remediation.

Accepted values:

- `false`: unlimited UAT remediation rounds
- `0`: unlimited UAT remediation rounds
- positive integer, the finite UAT remediation round cap

Injected default is `false`, and runtime fallback is also unlimited when the persisted value is absent or malformed. `/lbwc:config` rejects malformed interactive input instead of writing it.

Finite cap example:

```json
{
  "max_uat_remediation_rounds": 3
}
```

Unlimited example:

```json
{
  "max_uat_remediation_rounds": false
}
```

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/lbwc-brand-essentials.md (single-line box, ✓ success, ⚠ invalid, ➜ transitions, no ANSI).

## Next Up

After a successful mutation, show the validated current value and suggest `/lbwc:config` to review all settings. Stop after one suggestion.
