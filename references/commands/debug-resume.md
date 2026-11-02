Resume the active session or latest unresolved.

```bash
eval "$(bash "{plugin-root}/scripts/debug-session-state.sh" get-or-latest .lbwc-planning)"
```

If `active_session=none`, STOP "No active debug session to resume. Use `/lbwc:debug --session <id>` to open a specific session, or start one with `/lbwc:debug \"description of the bug or error message\"` or `/lbwc:debug <todo-number>`."
If `active_session=fallback`, inform the user which session the helper auto-selected (no `.active-session` pointer existed, so the helper chose the latest unresolved session automatically).
