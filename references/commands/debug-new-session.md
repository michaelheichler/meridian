If `SELECTED_TODO_MODE=true`, the selected-todo helper has already created or identified the session and has already handled Source Todo persistence plus root `STATE.md` pickup. Reuse `session_id`, `session_file`, and `session_status` from `SELECTED_TODO_START_JSON`, do not create another session and do not run selected-todo pickup in markdown.

For manual/freeform starts only, create a fresh session from $ARGUMENTS. Strip known flags (`--competing`, `--parallel`, `--serial`) and any `(ref:HASH)` suffix from $ARGUMENTS before computing the slug, these are routing/ref metadata, not part of the bug description.

```bash
eval "$(printf '%s' "$ARGUMENTS" | REF_HASH="${REF_HASH:-none}" DETAIL_STATUS="${DETAIL_STATUS:-none}" DETAIL_RESULT_JSON="${DETAIL_RESULT_JSON:-}" bash "{plugin-root}/scripts/debug-start-manual.sh" .lbwc-planning)"
```

Keep manual/freeform debug starts on the existing `start-with-source-todo` path. The selected helper owns deterministic selected-todo state mutation and returns pickup presentation fields under `.pickup`.
