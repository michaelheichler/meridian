Strip any known flags (`--competing`, `--parallel`, `--serial`) from $ARGUMENTS and store them separately for Step 2 routing. If `SELECTED_TODO_START_JSON` exists from the selected helper, reuse `.bug_desc` as the bug description, `.ref` as the selected ref, `.detail_status`, `.detail.context`, `.detail.files`, `.detail_has_signal`, `.accepted_exception_markers`, and `.routing_flags`, do not call `todo-details.sh` a second time and do not inspect raw selected-todo JSON to rediscover these fields. Otherwise, if the remaining $ARGUMENTS contains a `(ref:HASH)` suffix (8 hex characters), extract the hash as `REF_HASH` and strip the ref tag. Store remaining text (minus flags and ref) as the bug description. If you found a ref, load extended detail:

```bash
bash "{plugin-root}/scripts/todo-details.sh" get {hash}
```

Parse the JSON output. If `status` is `"ok"`, store `DETAIL_STATUS=ok`, store the exact helper stdout as `DETAIL_RESULT_JSON`, and store `detail.context` plus `detail.files` for use in Step 4. If `status` is `"not_found"` or `"error"`, clear `DETAIL_RESULT_JSON`, record the matching `DETAIL_STATUS` value, and run:

```bash
bash "{plugin-root}/scripts/todo-lifecycle.sh" detail-warning {hash}
```

In all cases, continue without detail.
If no ref suffix, $ARGUMENTS minus flags = bug description, `DETAIL_STATUS=none`, and `DETAIL_RESULT_JSON=""`.
**Post-parse validation:** If the bug description is empty or whitespace-only after stripping flags and ref, check whether you found a ref AND its detail loaded successfully (status `"ok"`). If yes, proceed, the detail provides the investigation context. If you found no ref, or the ref detail failed to load, STOP: "Usage: `/lbwc:debug \"description of the bug or error message\" [--competing|--parallel|--serial]` | `/lbwc:debug <todo-number> [--competing|--parallel|--serial]` | `/lbwc:debug --resume` | `/lbwc:debug --session <id>`".
Map effort with thorough=high, balanced/fast=medium, turbo=low.
Keep effort profile as `EFFORT_PROFILE` (thorough|balanced|fast|turbo).
Read `{plugin-root}/references/effort-profile-{profile}.md`.

**Bounded sparse-context enrichment (detail-first, then tiny helper):** Treat `DETAIL_STATUS=ok` as “lookup succeeded,” not automatically as “detail is useful.” For selected-todo mode, consume helper-provided `detail_has_signal` directly. For manual/freeform ref mode, compute the same value from `DETAIL_RESULT_JSON`, true only when loaded detail has actual signal, a non-empty `detail.context` or at least one related file. Otherwise, keep treating the item as sparse and run one bounded enrichment pass before final skill preselection:

```bash
DETAIL_HAS_SIGNAL=false
if [ "${SELECTED_TODO_MODE:-false}" = "true" ]; then
  DETAIL_HAS_SIGNAL=$(printf '%s' "$SELECTED_TODO_START_JSON" | jq -r '.detail_has_signal // false' 2>/dev/null || printf 'false')
elif [ "${DETAIL_STATUS:-none}" = "ok" ] && [ -n "${DETAIL_RESULT_JSON:-}" ]; then
  DETAIL_CONTEXT_FOR_ENRICHMENT=$(printf '%s' "$DETAIL_RESULT_JSON" | jq -r '.detail.context // ""' 2>/dev/null || printf '')
  DETAIL_FILE_COUNT_FOR_ENRICHMENT=$(printf '%s' "$DETAIL_RESULT_JSON" | jq -r '(.detail.files // []) | if type == "array" then length else 0 end' 2>/dev/null || printf '0')
  if [ -n "$DETAIL_CONTEXT_FOR_ENRICHMENT" ] || [ "${DETAIL_FILE_COUNT_FOR_ENRICHMENT:-0}" -gt 0 ]; then
    DETAIL_HAS_SIGNAL=true
  fi
fi

SPARSE_SKILL_ENRICHMENT_STATUS="skipped"
SPARSE_SKILL_ENRICHMENT_SUMMARY=""
SPARSE_SKILL_ENRICHMENT_FILES=""
SPARSE_SKILL_ENRICHMENT_MARKERS=""
if [ "$DETAIL_HAS_SIGNAL" != "true" ]; then
  SPARSE_SKILL_ENRICHMENT_JSON=$(printf '%s' "$BUG_DESC" | bash "{plugin-root}/scripts/debug-skill-enrichment.sh")
  SPARSE_SKILL_ENRICHMENT_STATUS=$(printf '%s' "$SPARSE_SKILL_ENRICHMENT_JSON" | jq -r '.status // "error"' 2>/dev/null || echo "error")
  if [ "$SPARSE_SKILL_ENRICHMENT_STATUS" = "ok" ]; then
    SPARSE_SKILL_ENRICHMENT_SUMMARY=$(printf '%s' "$SPARSE_SKILL_ENRICHMENT_JSON" | jq -r '.summary // empty' 2>/dev/null || echo "")
    SPARSE_SKILL_ENRICHMENT_FILES=$(printf '%s' "$SPARSE_SKILL_ENRICHMENT_JSON" | jq -r '(.matched_files // []) | join(", ")' 2>/dev/null || echo "")
    SPARSE_SKILL_ENRICHMENT_MARKERS=$(printf '%s' "$SPARSE_SKILL_ENRICHMENT_JSON" | jq -r '(.markers // []) | join(", ")' 2>/dev/null || echo "")
  fi
fi
```

The helper may return `no_signal` or `no_match`, treat those as bounded no-ops and continue. Prefer existing selected-todo metadata first, then this helper's 1-3 likely files / framework markers, then the raw description. Do not turn this into a broad repo scan.

<accepted_exception_debug_semantics>
Accepted exception/backlog markers are historical phase/round waivers and backlog pointers, not proof that a fix resolved the underlying issue. Known-issue sources include `[KNOWN-ISSUE]`, `Disposition: accepted-process-exception`, and `known_issue_signature.disposition`. UAT-deviation sources include `[UAT-DEVIATION]`, `source: "uat-deviation"`, an `uat_deviation` object, and the phrase `Accepted UAT summary deviation`. When the user selects the item with `/lbwc:debug <todo-number>`, treat it as an active remediation request. Do not set or accept `already_fixed` solely because source metadata says accepted, non-blocking, UAT deviation, process exception, or backlog. `already_fixed` requires fresh current evidence that the underlying issue no longer reproduces or the current branch already contains a real fix. If still actionable, use `resolution_observation=needs_change`, if impossible or unsafe without more input, use `resolution_observation=inconclusive`, Step 5 will normalize that field and map the no-commit session to `INVESTIGATION_OUTCOME=no_fix_yet`.

When selected helper output includes `accepted_exception_markers`, include one compact source-metadata sentence near this block using those labels. For manual/freeform detail, include the same kind of sentence when `DETAIL_RESULT_JSON` contains visible accepted-exception markers. Do not paste full JSON into spawned prompts.
</accepted_exception_debug_semantics>
