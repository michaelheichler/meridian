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
