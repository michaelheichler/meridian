Extract `SESSION_ID`, the token immediately following `--session` in $ARGUMENTS. If `--session` is present but no id follows it, STOP with `"--session requires a session id."` Otherwise, resume the named session:

```bash
eval "$(bash "{plugin-root}/scripts/debug-session-state.sh" resume .meridian "$SESSION_ID")"
```

If the session file is missing, STOP with error.
