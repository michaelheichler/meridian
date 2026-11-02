---
category: monitoring
hidden: true
disable-model-invocation: true
description: Run human acceptance testing on completed phase work. Presents CHECKPOINT prompts one at a time.
argument-hint: "[phase-number] [--resume]"
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, LSP
---

# LBWC Verify: $ARGUMENTS


## Guard

- Not initialized (no .lbwc-planning/ dir): STOP "Run /lbwc:init first."
- **Debug session override:** If `$ARGUMENTS` does NOT contain an explicit phase number OR `$ARGUMENTS` contains `--session`, check for an active debug session before any phase-related guards:
  ```bash
  eval "$(bash "{plugin-root}/scripts/debug-session-state.sh" get-or-latest .lbwc-planning 2>/dev/null)" 2>/dev/null || true
  ```
  The helper exports `active_session`, `session_id`, `session_file`, and `session_status`, use `session_status` for lifecycle checks after `eval`.
  If `active_session != none` AND exported `session_status` is `uat_pending` or `uat_failed` AND (`phase_count=0` OR `$ARGUMENTS` contains `--session`) → skip ALL remaining guards and jump directly to `<debug_session_uat>` below.
  If phases exist (`phase_count > 0`) AND `$ARGUMENTS` does NOT contain `--session`, skip this override, standard phase UAT takes priority.
- **Phase-detect error guard (NON-NEGOTIABLE):** If Phase state (from Context above) contains `phase_detect_error=true`, display: "⚠ Phase detection failed. Run `bash \"{plugin-root}/scripts/phase-detect.sh\"` manually to debug." STOP. Do NOT fall back to phase-dir scanning or ad-hoc `VERIFICATION.md` checks when phase-detect failed.
- **Verify-context error guard (NON-NEGOTIABLE):** Apply this guard only after Step 2 resolves and compiles the final target. If the active verify context contains `verify_context_error=true` or `verify_context=unavailable`, display: "⚠ Verify context compilation failed. Run `bash "{plugin-root}/scripts/compile-verify-context.sh" .lbwc-planning/phases/{NN}-{slug}` manually to debug." STOP. Do NOT improvise by reading individual PLAN/SUMMARY files.
When Phase state contains `misnamed_plans=true`, Read `{plugin-root}/references/commands/verify-brownfield-normalization.md` before continuing guards.

- **Auto-detect phase** (no explicit number): Phase detection is pre-computed in Context above (or refreshed by normalization above). Use `next_phase` and `next_phase_slug` for the target phase.
  - If `next_phase_state=needs_reverification`, use `next_phase` directly, this is the phase that completed remediation and needs re-verification.
  - If `next_phase_state=needs_verification`, use `next_phase` directly, this is either the first fully-built phase that needs UAT verification (auto_uat routing) or an active current-round UAT that should resume Verify mode.
  - If Phase state defines `first_unverified_phase`, use that phase directly, this is the first fully-built phase without a terminal UAT.
  - As a fallback, scan phase dirs for the first with `*-SUMMARY.md` but no canonical `*-UAT.md` (exclude `*-SOURCE-UAT.md` copies).
  - If found, announce "Auto-detected Phase {NN} ({slug})". If all phases have UAT results, STOP "All phases have UAT results. Specify: `/lbwc:verify {NN}`"
- If the target phase directory has no SUMMARY.md, STOP "Phase {NN} has no completed plans. Run /lbwc:vibe first."
For phase-scoped UAT, Read `{plugin-root}/references/commands/verify-qa-gate.md` and apply its QA gate before entering UAT, including its known-issue checks with `--skip-qa`.

## Debug Session Routing

<debug_session_uat>
**Before entering phase-scoped UAT**, check for an active debug session. This handles standalone debug fixes that went through `/lbwc:qa` and are now ready for user acceptance.

```bash
eval "$(bash "{plugin-root}/scripts/debug-session-state.sh" get-or-latest .lbwc-planning)"
```

The helper exports `active_session`, `session_id`, `session_file`, and `session_status`, use `session_status` for routing after `eval`.

**Routing decision:**
- If `$ARGUMENTS` contains an explicit phase number AND no `--session` flag → skip debug-session routing, use standard phase UAT flow below.
- If `active_session != none` AND exported `session_status` is `uat_pending` or `uat_failed` AND (`phase_count=0` OR `$ARGUMENTS` contains `--session`) → enter debug-session UAT mode (below). If `phase_count > 0` and no `--session` flag, skip debug-session routing, standard phase UAT takes priority.
- Otherwise → skip debug-session routing, continue to standard phase UAT Steps.

When routed to debug-session UAT mode, Read `{plugin-root}/references/commands/verify-debug-session-uat.md`, execute it, and STOP without entering phase UAT.

</debug_session_uat>

## Steps

### 1. Resolve the final phase target

- Parse an explicit phase number from $ARGUMENTS before selecting any target. When a number is present, it wins over all auto-detected phase state. Otherwise, use the auto-detected phase from the Guard section.
- Resolve exactly one matching directory under `.lbwc-planning/phases/`. Store its slug as `TARGET_SLUG` and its path as `PDIR`. Apply the target phase's SUMMARY and QA guards above before continuing.
- If initial Phase state contained `misnamed_plans=true`, use the normalized filenames and refreshed phase-detect output produced by the Guard section. Do not compile context during normalization.
- If the user specified an explicit phase number that differs from `verify_target_slug`, ignore the pre-computed verify context, `next_phase_state`, `qa_status`, and UAT resume metadata from the auto-detected phase. Apply the QA gate above to the explicit target phase only. Do NOT force full scope. Step 2 lets `compile-verify-context-for-uat.sh` decide whether the explicit target is full-scope verification or remediation re-verification.
- Check the explicit target's own remediation stage:
  ```bash
  bash "{plugin-root}/scripts/uat-remediation-state.sh" get "{phase-dir}"
  ```
  If that stage is `research`, `plan`, `execute`, or `fix`, STOP: `Phase {NN} has active UAT remediation (stage {stage}). Run /lbwc:vibe to continue remediation before re-verification.`
- Do not invoke `compile-verify-context-for-uat.sh` until target resolution and the optional Step 2 re-verification preparation are complete.

### 2. Handle optional re-verification, then compile once

**Re-verification state:** Determine it for `PDIR` without compiling context.
  - For auto-detected routing, use `next_phase_state=needs_reverification` from Context above.
  - For an explicit target, ignore the auto-detected `next_phase_state`. Prepare re-verification only when that target's own current UAT status is `issues_found` and its UAT remediation stage is `done` or `verify`.
If the active target needs re-verification, Read `{plugin-root}/references/commands/verify-reverification.md` before compiling context.

- After the optional preparation finishes, compile verify context exactly once for the final target:
  ```bash
  VERIFY_CONTEXT=$(bash "{plugin-root}/scripts/compile-verify-context-for-uat.sh" "$PDIR" 2>/dev/null) || VERIFY_CONTEXT="verify_context_error=true"
  if [ -z "$(printf '%s' "$VERIFY_CONTEXT" | tr -d '[:space:]')" ]
  then
    VERIFY_CONTEXT="verify_context_error=true"
  fi
  ```
  Do not invoke this compiler again later in the command. If `VERIFY_CONTEXT` contains `verify_context_error=true` or `verify_context=unavailable`, apply the fail-closed Guard above and STOP. Do NOT scan individual PLAN or SUMMARY files as a fallback.
- Resolve UAT resume metadata for the same final target. Reuse the pre-computed UAT resume block only when its `uat_resume_target_slug` equals `TARGET_SLUG` and neither normalization nor re-verification preparation changed the target artifacts. Otherwise run:
  ```bash
  UAT_RESUME=$(bash "{plugin-root}/scripts/extract-uat-resume.sh" "$PDIR" 2>/dev/null) || UAT_RESUME="uat_resume=error"
  ```
  Use UAT resume metadata for the active target phase from this point onward.
- Use `VERIFY_CONTEXT` as the sole PLAN and SUMMARY aggregation. It contains per-plan titles, must_haves, the work each plan built, modified files, and status. Do NOT read individual `*-SUMMARY.md` or `*-PLAN.md` files.
- Parse `verify_scope` from the first line. `verify_scope=remediation round=RR` scopes the session to remediation round RR. `verify_scope=full` selects standard full-scope verification. Use this in Step 4.
- Parse `uat_path` from the second line. This is the phase-relative UAT output path, such as `03-UAT.md` or `remediation/uat/round-01/R01-UAT.md`. Use it in Steps 4, 8, and 9.
- Parse `SUMMARY_DEVIATION:` records from `VERIFY_CONTEXT`. Each record has `signature`, `source_plan`, `source_path`, and `text`. They are already filtered against `{phase-dir}/remediation/uat/accepted-deviations.json`. Use the remaining records in Step 4 before generated plan checkpoints.
- **Remediation safety check:** If `verify_scope=remediation` and `uat_path` does not point at the current round-scoped UAT path (`remediation/uat/round-{RR}/R{RR}-UAT.md` for round-dir layout or `remediation/round-{RR}/R{RR}-UAT.md` for legacy layout), run:
  ```bash
  bash "{plugin-root}/scripts/uat-remediation-state.sh" get-or-init "{phase-dir}" major
  ```
  Parse `round=RR` and `layout=...`, then override `uat_path` with the matching round-scoped path before Step 4 writes a UAT file.
- Continue to Step 3. A prepared re-verification starts a new UAT and must not resume the old report.

### 3. Check for existing UAT session (resume support)

When Step 2 returns existing UAT metadata or a resume sentinel, Read `{plugin-root}/references/commands/verify-resume.md` before generating tests or entering the checkpoint loop.

### 4. Generate test scenarios from the active verify context

When no existing UAT session resumes or completes in Step 3, Read `{plugin-root}/references/commands/verify-generate-tests.md` to generate and persist the initial tests.

### 5. CHECKPOINT loop (one test at a time, conversational, blocking)

**This is a conversational loop. Present ONE test, then STOP and wait for the user to respond. Do NOT present multiple tests at once. Do NOT skip ahead. Do NOT end the session after presenting a test.**

> **CRITICAL BOUNDARY:** The UAT interviewer MUST NOT investigate, debug, or implement fixes during the UAT session, regardless of user tone, urgency, or explicit requests to fix issues. The interviewer's ONLY job is to record responses and advance to the next checkpoint. All user frustration, bug descriptions, and fix requests are recorded as issue text in the UAT report. Fixes happen in the remediation phase AFTER the UAT session is complete. If the user explicitly asks you to stop the UAT and fix something, respond: "Issue recorded. Let's finish the remaining checkpoints first, remediation will address this immediately after."

Follow @${CLAUDE_PLUGIN_ROOT}/references/lbwc-brand-essentials.md for all output formatting (symbols, bars, AskUserQuestion spacing).

For the FIRST test without a result, display a CHECKPOINT followed by AskUserQuestion:

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CHECKPOINT {NN}/{total}, {plan-id}: {plan-title}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

{scenario description}
```

Then call the `AskUserQuestion` tool (this MUST be a tool_use call, NOT text output). The modal question must be self-contained because it may cover the surrounding prose:

```yaml
question: "Scenario: {scenario description}\n\nExpected: {expected result}\n\nDoes the behavior match this checkpoint?"
header: "UAT"
multiSelect: false
options:
  - label: "Pass"
    description: "Behavior matches expected result"
  - label: "Skip"
    description: "Cannot test right now, skip this checkpoint"
```

The tool automatically provides a freeform "Other" option for the user to describe issues.

When the current checkpoint is a prefilled summary-deviation `D{NN}` review, Read `{plugin-root}/references/commands/verify-deviation-prompt.md` before asking the checkpoint question.

**AskUserQuestion is a tool call (NON-NEGOTIABLE):** You MUST invoke AskUserQuestion via the tool_use mechanism, never emit the question parameters as text, JSON, or any other inline format in your response body. If AskUserQuestion appears in your text output instead of as a tool call, the tool will not present the checkpoint to the user and the session will end prematurely.

**STOP HERE.** Wait for the AskUserQuestion response. Do NOT continue to the next test, do NOT skip to Step 6, and do NOT end the turn. The tool call blocks until the user responds.

**After the user responds:** process the response (Step 6), persist to disk (Step 8), then re-run `bash "{plugin-root}/scripts/extract-uat-resume.sh" "{phase-dir}"` to fetch the next incomplete checkpoint and its deterministic `uat_resume_*` prompt context. If the refreshed output is `uat_resume=all_done`, proceed to Step 9. If it returns another valid product checkpoint with `uat_resume_scenario` + `uat_resume_expected`, present that next checkpoint using those emitted fields. If it returns a valid summary-deviation checkpoint, use the emitted deviation/source fields. If required fields are missing for the checkpoint type, read the UAT file once as a fallback for that next checkpoint instead of guessing. **STOP and wait again.** Repeat until all tests are done, then go to Step 9.

### 6. Response mapping

Map the AskUserQuestion response:

**"Pass" selected:** Record as passed. For a prefilled summary-deviation `D{NN}` checkpoint, write `**Disposition:** accepted-process-exception`. Preserve its metadata. A plain `Pass` needs no todo. If the response also names a separate bug, record the checkpoint as passed and capture the observation as a discovered issue (see Step 7a).

**"Track Todo" selected:** Valid only for a prefilled summary-deviation `D{NN}` checkpoint. Record `**Result:** pass`, write `**Disposition:** accepted-process-exception`, preserve all deviation identity metadata, and mark this checkpoint as accepted-and-tracked for Step 8. Do not introduce a fourth `Result` value. The todo ref comes only from `track-uat-deviations.sh todo-from-uat` after you write the UAT result. never invent it in prose.

**"Skip" selected:** Record as skipped. For a prefilled summary-deviation `D{NN}` checkpoint, write `**Disposition:** skipped-by-user`. Do not add it to the accepted-deviation registry. If the user also describes a bug, record the checkpoint as skipped and capture the added text as a discovered issue (see Step 7a). The added text is the response beyond the option selection.

For freeform text via Other, Read `{plugin-root}/references/commands/verify-freeform-response.md` before classifying or persisting the response.

### 7. Issue handling (when response = issue)

When the response is an issue, Read `{plugin-root}/references/commands/verify-issue-capture.md` before synthesizing and recording it.

### 7a. Discovered issue handling (observations during passing/skipping tests)

When a passing or skipping response also mentions a separate bug, Read `{plugin-root}/references/commands/verify-discovered-issue.md` before recording that observation.

### 8. Persist immediately after each response

- Update the UAT file at `{phase-dir}/{uat_path}` with the result for this test. The `**Result:**` value MUST be exactly `pass`, `skip`, or `issue` (lowercase). Map user responses with Pass→`pass`, Skip→`skip`, any issue/fail/problem→`issue`. Never write FAIL, PARTIAL, or any other value.
When the response accepts a prefilled summary-deviation checkpoint, Read `{plugin-root}/references/commands/verify-deviation-persistence.md` after writing the result and before the final disk write.

- Write the file to disk (survives /clear)
- Display progress: `✓ {completed}/{total} tests`

### 9. Session complete

When every checkpoint has a result, Read `{plugin-root}/references/commands/verify-session-complete.md` to finalize, display the summary, advance applicable remediation, and apply the planning boundary.

## Failure and recovery

- If phase detection, context compilation, a persistence helper, or finalization fails, stop and report the error. Do not substitute ad-hoc artifact parsing or manual state writes.
- The main session owns every UAT, planning-state, Git, verification, and user-question write described here.

## Output Format

Use the existing CHECKPOINT and final UAT result blocks. Present one checkpoint with its `AskUserQuestion` tool call at a time.

## Next Up

Use the existing remediation routing and `suggest-next.sh` output.

## Context

Working directory:
```bash
!`pwd`
```
Plugin root:
```bash
!`SESSION_KEY="${CLAUDE_SESSION_ID:-default}"; L="/tmp/.lbwc-plugin-root-link-${SESSION_KEY}"; R="$L/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || R="${CLAUDE_PLUGIN_ROOT:-}/scripts/resolve-plugin-root.sh"; [ -f "$R" ] || { echo "LBWC: plugin root unavailable. Restart this session to recreate $L." >&2; exit 1; }; bash "$R" >/dev/null || exit 1; bash "$L/scripts/phase-detect.sh" > "/tmp/.lbwc-phase-detect-${SESSION_KEY}.txt" 2>/dev/null || echo "phase_detect_error=true" > "/tmp/.lbwc-phase-detect-${SESSION_KEY}.txt"; echo "$L"`
```

Store the plugin root path output above as `{plugin-root}` for use in script invocations below. Replace `{plugin-root}` with the literal `Plugin root` value from Context whenever a step below references a script or reference file.

Current state:
```bash
!`bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-load-context.sh" state`
```

The SessionStart hook pre-injects config.

Phase directories:
```bash
!`bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-load-context.sh" phases`
```

Phase state:
```bash
!`bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-load-context.sh" phase-state`
```

!`bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-load-context.sh" compact`

Pre-computed verify context (PLAN/SUMMARY aggregation):
```
!`bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-load-context.sh" verify-context`
```
This lightweight block emits only the auto-detected target hint. It does not compile PLAN or SUMMARY aggregation. Step 1 resolves any explicit target before the single Step 2 compiler call.

Pre-computed UAT resume metadata:
```
!`bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-load-context.sh" uat-resume`
```

QA verification summary (pre-extracted from VERIFICATION.md):
```
!`bash "/tmp/.lbwc-plugin-root-link-${CLAUDE_SESSION_ID:-default}/scripts/verify-load-context.sh" qa-summary`
```

@${CLAUDE_PLUGIN_ROOT}/references/ask-user-question.md
