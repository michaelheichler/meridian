# T002 Documented config keys without runtime behavior

Status is open. Found on 1f676fa by the config key check from the debug_logging task.

## Keys

| Key | Documented at | Values | What reads it today |
| --- | --- | --- | --- |
| `tmux_execution.cleanup_policy` | `commands/config.md:276` and `:316` | `kill_on_complete`, `keep_panes` | only validation in `scripts/lib/lbwc-config-validate.jq:53` and the freeze list in `scripts/lib/lbwc-config-freeze.sh` |
| `worktree_isolation` | `commands/config.md:297` | `off`, `on` | only validation in `scripts/lib/lbwc-config-validate.jq:120` and the parity file |

The `cleanup_policy` placeholders in `commands/fix.md` and `references/vibe-input-parsing.md` belong to todo pickup and do not read this key.

## Plan

The owner rule says no feature gets cut, so both keys get real behavior.

1. `keep_panes` makes teardown keep the agent panes open while it still clears the runtime state. `kill_on_complete` keeps today's behavior. The work touches `scripts/lib/tmux-agent-orchestrator-teardown.sh`, so it starts after T001 merges.
2. `worktree_isolation=on` makes every spawned code-writing worker run in its own git worktree. `scripts/agent-spawn-guard.sh` already detects a requested isolation at line 56 and is the starting point.

## Added scope

- T002b. `scripts/file-guard.sh` `validate_manifest_allowance` (lines 108-118) requires the worker git root to equal the manifest `project_root`, so isolated workers cannot edit. Accept a worktree root only when its physical git common dir equals the project's, `git worktree list` lists it, and it sits under `.claude/worktrees/` or the tmux-owned worktree dir. Every other allowance check stays as strict, relative to the worktree root.
- T002c. `tmux_execution.restrictions` and its four booleans (`allow_nested_spawn`, `allow_agent_git`, `allow_agent_ask_user`, `require_orchestrator_attach`) get only shape checks in `scripts/runtime-snapshot.sh:53-57` and `:157-160`. Nothing enforces them. Each needs a real enforcement point for tmux agents.
- Owner decision needed for `tmux_execution.restrictions.require_orchestrator_attach` (default true). No code checks tmux client attachment today. `attach_policy` only picks pane focus and layout, and every split already requires the authenticated main orchestrator. Enforcing "a tmux client must be attached" by default would break detached-session provisioning, which works today. Options are (a) enforce client attachment and change the default to false, (b) enforce it with default true and accept the behavior change, (c) document the key as reserved.
- The workflow backend has no isolation field, so `worktree_isolation=on` fails closed there with one clear message.

## Done when

- Each key changes behavior as documented, and the default keeps today's behavior.
- The config key check reports no missing reader.
- Tests cover both values of each key within the 500-test budget.
