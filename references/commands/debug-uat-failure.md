If resuming a session with `session_status=uat_failed`, load failure context:

```bash
FAILURE_CONTEXT=$(bash "{plugin-root}/scripts/compile-debug-session-context.sh" "$session_file" uat 2>/dev/null || echo "")
```

Update status to `investigating` via `write-debug-session.sh` (mode=status), then continue investigation from Step 3. When composing the debugger task prompt in Step 4, prepend the compiled `FAILURE_CONTEXT` to the bug report so the debugger has the specific failed UAT issues and findings. Use this format in the task prompt: `Previous UAT failed. Failure context:\n{FAILURE_CONTEXT}\n\nOriginal bug report: {description}`.
