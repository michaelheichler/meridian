---
category: advanced
disable-model-invocation: true
description: Remove all Meridian traces from the system before plugin uninstall.
argument-hint: "[--check]"
allowed-tools: Read, Write, Edit, Bash, Glob, AskUserQuestion
---

# Meridian Uninstall

## Context

Settings:
```
!`for _d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.config/claude-code" "$HOME/.claude"; do [ -z "$_d" ] && continue; [ -f "$_d/settings.json" ] && cat "$_d/settings.json" 2>/dev/null && break; done || echo "{}"`
```
Planning dir:
```text
!`ls -d .meridian 2>/dev/null && echo "EXISTS" || echo "NONE"`
```
CLAUDE.md:
```text
!`ls CLAUDE.md 2>/dev/null && echo "EXISTS" || echo "NONE"`
```

@${CLAUDE_PLUGIN_ROOT}/references/ask-user-question.md

## Steps

**Resolve config directory.** Try `CLAUDE_CONFIG_DIR` first if it names an existing directory, then `~/.config/claude-code` if it exists, and otherwise `~/.claude`. Store the result as `CLAUDE_DIR`.

### Step 1. Confirm intent

Display the Phase Banner "Meridian Uninstall" and explain system-level config removal. Handle project files separately and ask for confirmation.

### Step 2. Clean statusLine

Read `CLAUDE_DIR/settings.json`. If `statusLine` contains `meridian-statusline`, remove the entire `statusLine` key and display ✓. Otherwise display "○ Meridian does not own this statusline, skipped".

### Step 3. Clean Agent Teams env var

If `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` exists, ask the user before removing it because other tools may use this Claude Code feature. If the user approves, remove the variable and remove the `env` key if it becomes empty. Otherwise display "○ Agent Teams setting kept".

### Step 4. Project data

If `.meridian/` exists, ask whether to keep it (recommended) or delete it. Only after the user chooses deletion, run `rm -rf .meridian/`.

### Step 5. CLAUDE.md cleanup

If CLAUDE.md exists, ask whether to keep or delete it.

### Step 6. Summary

Display the Phase Banner "Meridian Cleanup Complete" with ✓ or ○ for each step, followed by these instructions.
```
➜ Final Step
  /plugin uninstall meridian@meridian-marketplace
  Then optionally: /plugin marketplace remove meridian-marketplace
```
**Do not run plugin uninstall yourself**, because it would remove the plugin during execution.

## Output Format

Follow @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md. Use the Phase Banner (double-line box), ✓ for completed steps and ○ for skipped steps, followed by Next Up. Do not use ANSI.

## Guard

Require explicit uninstall intent and list every Meridian-owned path before deletion. Do not remove project source or unrelated Claude configuration. Keep shared third-party state.

## Failure and recovery

On any failed removal, stop and report the exact remaining Meridian path. Never claim a complete uninstall while residue remains.

## Next Up

After verification, instruct the user to remove the plugin through Claude Code plugin management.
