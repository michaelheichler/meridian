<selected_todo_start_helper>
Selected-todo mode applies when the user input above, after removing only supported routing flags (`--competing`, `--parallel`, `--serial`), contains exactly one numeric token and no other freeform text. Preserve those supported routing flags and pass them through to the helper. Any other text stays on the manual/freeform debug path.

When selected-todo mode applies, call the deterministic helper exactly once:

```bash
bash "{plugin-root}/scripts/debug-start-selected-todo.sh" .meridian <N> [--competing|--parallel|--serial]
```

Treat the helper stdout as `helper_output`, the single source of truth for selected-todo startup. The helper owns numbered selection resolution, optional detail loading, completed-session stale-state repair, debug session creation, `## Source Todo` persistence, and selected-todo pickup from writable root `STATE.md`. Do not reimplement those state transitions in command markdown.

Helper output schema is status-variant. Always parse `.status` before reading branch-specific fields.

- The common discriminator `status` is `ok`, `already_complete`, or `error`.
- Success-like payloads (`ok` and `already_complete`) include the full selected-todo payload: `mode`, `todo_selected`, `bug_desc`, `routing_flags`, `selected`, `ref`, `detail_status`, `detail`, `detail_has_signal`, `accepted_exception_markers`, `detail_warning`, `session`, `pickup`, and `message` when applicable. `pickup` contains `status`, `warning`, `auto_note`, and `result`.
- No-session errors may carry only `status`, `code`, and `message`, plus any resolver-owned error fields. Do not assume `mode`, `bug_desc`, `routing_flags`, `selected`, `ref`, `detail_*`, `accepted_exception_markers`, `session`, or `pickup` exists on this branch.
- Errors with a session carry `status`, `code`, `message`, `mode`, `todo_selected`, `session`, and usually `pickup` so the command can expose partial lifecycle state. Do not require success-only selected/detail fields on this branch.

Parse `.status` first and branch explicitly:

- If `.status == "ok"`, store `SELECTED_TODO_MODE=true`, store `SELECTED_TODO_START_JSON=helper_output`, use `.bug_desc` as the working bug description, set `session_id=.session.id`, `session_file=.session.file`, and `session_status=.session.status`, then continue the workflow using helper-provided fields.
- If `.status == "already_complete"`, show the completed session id/file/status, the helper message, and any pickup warning. STOP. Do not create, resume, or investigate another session.
- If `.status == "error"` and `.session` exists, show that the debug session already exists or that the helper created it before the pickup/session error, include `.session.id`, `.session.file`, `.session.status`, surface `.message`, and tell the user to inspect or resume that session instead of implying no session exists. STOP.
- For any other error, STOP with `.message // "Selected todo startup failed. Rerun /meridian:list-todos and try again."`.

All selected-todo consumers must read `SELECTED_TODO_START_JSON`. Parse/effort uses `.bug_desc` and `.ref`, sparse enrichment uses `.detail_has_signal`, `.detail.context`, and `.detail.files`, accepted-exception prompt text uses `.accepted_exception_markers`, pickup UX uses `.pickup.*`. The command must not preserve selected-todo JSON variables, preserve raw detail-helper JSON for the selected path, or pipe selected-todo JSON between resolver/detail/session/pickup helpers.
</selected_todo_start_helper>
