The user now has project-defining files and can run `/meridian:transit` when ready.
Display a banner per @${CLAUDE_PLUGIN_ROOT}/references/meridian-brand-essentials.md with the title "MERIDIAN Initialization Complete".

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MERIDIAN Initialization Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Display all files that this command created or updated.
Include the core project artifacts.

- `✓ .meridian/PROJECT.md`
- `✓ .meridian/REQUIREMENTS.md`
- `✓ .meridian/ROADMAP.md`
- `✓ .meridian/STATE.md`

Include configuration and instructions.

- `✓ CLAUDE.md`
- `✓ .meridian/config.json`

Include conditional artifacts only when their conditions apply.

- If planning_tracking=commit and changes existed, display `✓ Bootstrap planning artifacts committed`.
- If BROWNFIELD=true, display `✓ Codebase mapped`.

Display the next steps.

```text
➜ Next: Run /meridian:transit to start planning your first milestone
  Or:   Run /meridian:status to review project state
```
