**Check `verify_scope` in `VERIFY_CONTEXT`.** Two modes:

**Re-verification mode** (`verify_scope=remediation round=RR`): The context contains ONLY plans from the latest remediation round. These plans fixed issues found in a previous UAT session. Frame test scenarios to verify the remediation worked:
- Each plan's `must_haves` reference the original UAT issues that its remediation addressed
- Generate 1-3 tests per plan focused on: "The original issue was {must_have description}. Verify the fix resolves it."
- Tests should confirm the specific bug/issue is no longer present, not re-test the entire phase
- Use remediation checkpoint IDs `PR{RR}-T{NN}` (for example, `PR03-T01`) for generated remediation tests, same UAT.md template, same rules below

**Full-scope mode** (`verify_scope=full`): Standard verification of all phase plans. Use the rules below as-is.

**Summary deviation review prefill (NON-NEGOTIABLE):** Before generating plan checkpoints, inspect the parsed `SUMMARY_DEVIATION:` records from the verify context.
**Create checkpoints:** For each record, create one `D{NN}` checkpoint before generated `P...` or `PR...` tests. Number them in their stable verify-context order.
**Review status:** These are not pre-recorded failures. Start `**Result:**` empty. Mark `issue` only when the human rejects the deviation or reports a real bug.
**Identity metadata:** Write `**Source:** Summary deviation review`, `**Deviation Signature:** {signature}`, `**Source Plan:** {source_plan}`, `**Source Summary:** {source_path}`, and `**Deviation:** {text}`.
- Write `**Expected:** Human confirms whether this documented deviation is acceptable for this phase.`
- Initial frontmatter `total_tests` includes these `D{NN}` review checkpoints plus generated plan checkpoints. Initial `issues` remains `0`, count unresolved review checkpoints as incomplete until the human answers.
- If there are no `SUMMARY_DEVIATION:` records, do not create any prefilled deviation checkpoints.

For each plan in `VERIFY_CONTEXT`:
- Use the pre-computed `what_was_built`, `files_modified`, and `must_haves` data. Do NOT read SUMMARY.md or PLAN.md files.
- Generate 1-3 test scenarios that require HUMAN judgment, things only a person can verify
- Minimum 1 test per plan, even for pure refactors (use "verify nothing broke" regression test)
- Full-scope test IDs follow the format: `P{plan}-T{NN}` (e.g., P01-T1, P01-T2, P02-T1). Re-verification test IDs follow the format `PR{RR}-T{NN}`.

**UAT tests must be things only a human can judge.** Good examples:
- Open the app and navigate to screen X, does it display Y correctly?
- Perform user workflow A → B → C, does the result look right?
- Check that the UI reflects the change, is the label/value/layout correct?

**NEVER generate tests that ask the user to run automated checks.** These belong in the QA phase, not UAT:
- ✗ Run a test suite or individual test (xcodebuild test, pytest, bats, jest, etc.)
- ✗ Run a CLI command and check its exit code or output
- ✗ Execute a script and verify it passes
- ✗ Run a linter, type-checker, or build command

For backend, test, or script changes, ask the human to verify a visible effect. For example, ask them to confirm that the migration preview no longer shows phantom entries. Do not ask them to run tests.

**What belongs in UAT (ask the user):**
- Visual/UI correctness ("Does the migration preview show the correct symbols?")
- Domain-specific data validation ("Does the reconciliation output match your expected portfolio?")
- UX flows and usability ("Navigate to Settings > Import, does the flow feel right?")
- Behavior that requires the running app or hardware ("Open the app on your device, tap X, verify Y")
- Subjective quality ("Does the chart render clearly at different screen sizes?")

**What does NOT belong in UAT (the agent or QA already handles these):**
- Running test suites, QA runs these during execution. Do NOT ask the user to run tests.
- Checking command output, exit codes, or build success
- Grepping files for expected content
- Verifying file existence or structure
- Any check that the agent can perform programmatically via Bash, Grep, or Glob

**Skill-aware exclusion:** UI automation capabilities available through skills, tools, or MCP servers belong in QA, not UAT. This includes describe-UI, tap/click simulation, accessibility inspection, screenshot capture, and DOM querying. Only include scenarios that require true human judgment, subjective quality, visual design assessment, domain data correctness, or hardware-dependent behavior that available tooling cannot automate.

If a plan's work is purely internal (refactor, test infrastructure, script changes) with no user-facing behavior, create one lightweight checkpoint. Ask the user to confirm that the app still works from their perspective, rather than asking them to run automated checks.

Write the initial UAT file at `{phase-dir}/{uat_path}` (using the pre-computed `uat_path` from Step 1) using the `templates/UAT.md` format. If the parent directory doesn't exist (e.g., `remediation/uat/round-01/`), create it first.
- Populate YAML frontmatter with phase, plan_count, status=in_progress, started=today, total_tests
- Write prefilled `D{NN}` summary-deviation review entries first, then generated plan checkpoint entries. All entries start with Result fields empty (no placeholder values).

**Result field values (NON-NEGOTIABLE):** The `**Result:**` field in each test entry MUST be exactly one of three lowercase values: `pass`, `skip`, or `issue`. Never write `FAIL`, `PARTIAL`, `PASS`, `PASSED`, or any other value, downstream scripts depend on this exact vocabulary to extract issues and compute status.
