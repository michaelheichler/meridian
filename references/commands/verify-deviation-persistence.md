- When the response accepts and tracks a prefilled summary-deviation checkpoint (`Track Todo` or the summary-deviation todo-intent freeform path), run todo promotion after writing the UAT file and before accepted-deviation registry sync:
  ```bash
  TODO_META=$(bash "{plugin-root}/scripts/track-uat-deviations.sh" todo-from-uat "{phase-dir}" "{phase-dir}/{uat_path}" "{test-id}" 2>/dev/null || true)
  TODO_STATUS=$(printf '%s\n' "$TODO_META" | awk -F= '/^todo_status=/{print $2; exit}')
  TODO_REF=$(printf '%s\n' "$TODO_META" | awk -F= '/^todo_ref=/{print $2; exit}')
  ```
  - If `TODO_STATUS=added` and `TODO_REF` is non-empty, write or update the checkpoint line to `**Tracking:** accepted deviation added to todos (ref:{TODO_REF})`.
  - If `TODO_STATUS=already_tracked` and `TODO_REF` is non-empty, write or update the checkpoint line to `**Tracking:** accepted deviation already tracked in todos (ref:{TODO_REF})`.
  - If `TODO_STATUS` is `no_state_file`, `missing_metadata`, `not_accepted`, empty, or any other value, keep `**Result:** pass` and write `**Tracking:** accepted deviation todo tracking unavailable ({TODO_STATUS:-helper_failed})`. The human acceptance controls whether the deviation blocks the phase. helper failure only affects follow-up tracking.
  - Never invent a todo ref. Only use `TODO_REF` emitted by the helper.
- When the response accepts a prefilled summary-deviation checkpoint (`D{NN}` with `**Deviation Signature:** ...` and `**Disposition:** accepted-process-exception`), run the accepted-deviation registry helper after any todo tracking update:
  ```bash
  bash "{plugin-root}/scripts/track-uat-deviations.sh" record-from-uat "{phase-dir}" "{phase-dir}/{uat_path}"
  ```
  The helper is idempotent. Do not hand-edit `accepted-deviations.json`.
