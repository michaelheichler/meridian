When a user passes or skips a test but also mentions a separate bug, issue, or observation unrelated to the test's expected behavior, capture the separate observation as a discovered issue (see Step 7a).


Assign a discovered-issue ID of `D{NN}` (D01, D02, ...), sequential across the UAT session. Before appending any discovered issue, scan the current UAT file at `{phase-dir}/{uat_path}` in both initial and resumed sessions for existing `D[0-9]+` headings. Include prefilled summary-deviation review entries and discovered issues already appended earlier in the same session. Reserve those IDs. Allocate the next zero-padded `D{NN}` from highest existing + 1, or `D01` when none exist. For example, if prefilled `D01` and `D02` already exist, the next discovered issue is `D03`. Never renumber existing `D{NN}` entries.

Read `{plugin-root}/references/commands/verify-issue-capture.md` for its shared issue capture rules and severity table, then infer severity using that Step 7 keyword table. Infer category from context:
- If the user identifies a specific view/screen/component, use that as the description prefix.
- If vague, use the checkpoint context and user observation to synthesize a concise remediation-ready description instead of persisting filler or transient attachment placeholders.

The captured observation is source material for Step 7 issue capture rules. Synthesize the persisted `Description`, do not copy it verbatim.

Append a new test entry to the UAT.md `## Tests` section:

```markdown
### D{NN}: {short-title}

- **Plan:** (discovered during {test-id})
- **Scenario:** User observation during UAT
- **Expected:** (not applicable, discovered issue)
- **Result:** issue
- **Issue:**
  - Description: {synthesized remediation-ready description}
  - Severity: {inferred severity}
```

Increment `total_tests` and `issues` in frontmatter. This ensures discovered issues flow into UAT remediation alongside test failures.

Display:
```text
Discovered issue D{NN} recorded (severity: {level}).
```
