#!/usr/bin/env bats

load test_helper
load compile_verify_helper

setup() {
  cvc_setup
}

teardown() {
  teardown_temp_dir
}

@test "compile-verify-context lists FAIL history rows, picks the source verification, and tracks each original FAIL" {
  cvc_run_cases <<'CASES'
== phase-level-verification-history
@plan 03-01-PLAN.md|01|Test plan|Item one
@sum 03-01-SUMMARY.md|complete|Feature A
@vt 03-VERIFICATION.md|FAIL
@row MH-01|Item one|FAIL|Missing
@row MH-02|Item two|PASS|Done
?+ === VERIFICATION HISTORY ===
?+ --- Phase VERIFICATION (FAIL) ---
?< FAIL>>Missing
?- Item two
== history-compounds-across-rounds
@plan 03-01-PLAN.md|01|Test plan|Widget renders fast
@sum 03-01-SUMMARY.md|complete|Widget
@vt 03-VERIFICATION.md|FAIL
@row MH-01|Widget renders within 200ms|FAIL|Measured 350ms
@row ART-03|Test coverage|FAIL|No test file
@round qa|01|Fix widget speed|complete|Optimized widget|Faster widget
@vt remediation/qa/round-01/R01-VERIFICATION.md|PARTIAL
@row MH-01|Widget renders within 200ms|FAIL|Measured 210ms
@row ART-03|Test coverage|PASS|Tests added
?+ === VERIFICATION HISTORY ===
?+ --- Phase VERIFICATION (FAIL) ---
?+ 350ms
?+ --- Round 01 VERIFICATION (PARTIAL) ---
?+ 210ms
== no-history-without-verification-files
@plan 03-01-PLAN.md|01|Test plan|
@sum 03-01-SUMMARY.md|complete|Feature
?- === VERIFICATION HISTORY ===
== history-skips-pass-rows
@plan 03-01-PLAN.md|01|Test plan|
@sum 03-01-SUMMARY.md|complete|Feature
@vt 03-VERIFICATION.md|FAIL
@row MH-01|Good thing|PASS|Works
@row MH-02|Bad thing|FAIL|Broken
@row MH-03|Also good|PASS|Fine
?+ === VERIFICATION HISTORY ===
?< Bad thing>>FAIL
?h- PASS
== round-only-history-without-phase-verification
@plan 03-01-PLAN.md|01|Test plan|
@sum 03-01-SUMMARY.md|complete|Feature
@round qa|01|Fix issues|complete|Fixes|
@vt remediation/qa/round-01/R01-VERIFICATION.md|PARTIAL
@row MH-01|Speed check|FAIL|Still slow
@row MH-02|Test check|PASS|Tests added
?+ === VERIFICATION HISTORY ===
?+ --- Round 01 VERIFICATION (PARTIAL) ---
?+ Still slow
?- --- Phase VERIFICATION
== history-falls-back-to-plain-verification-file
@plan 03-01-PLAN.md|01|Brownfield plan|Preserve original failure history
@sum 03-01-SUMMARY.md|complete|Feature
@vt VERIFICATION.md|FAIL
@row MH-01|Brownfield failure|FAIL|Still broken
@row MH-02|Other check|PASS|Fine
?+ === VERIFICATION HISTORY ===
?+ --- Phase VERIFICATION (FAIL) ---
?+ Brownfield failure
?- Other check
== fail-word-in-description-column-is-not-a-fail-row
@plan 03-01-PLAN.md|01|Test plan|
@sum 03-01-SUMMARY.md|complete|Feature
@vt 03-VERIFICATION.md|PASS
@row MH-01|Verify FAIL message rendering|PASS|Works correctly
@row MH-02|Error handling|PASS|All good
?+ === VERIFICATION HISTORY ===
?h- FAIL message rendering
== six-column-artifact-tables-yield-fail-rows
@plan 03-01-PLAN.md|01|Test plan|
@sum 03-01-SUMMARY.md|complete|Feature
@v 03-VERIFICATION.md|FAIL
@h Must-Have Checks
| %N | ID | Description | Status | Evidence |
|---|-----|-------------|--------|----------|
| 1 | MH-01 | Widget speed | PASS | Fast |
| 2 | MH-02 | Widget accuracy | FAIL | Off by 10% |
@h Artifact Checks
| %N | ID | Artifact | Exists | Contains | Status |
|---|-----|----------|--------|----------|--------|
| 1 | ART-01 | tests/widget.test.ts | Yes | Coverage | PASS |
| 2 | ART-02 | docs/api.md | No | - | FAIL |
@h Key Link Checks
| %N | ID | From | To | Via | Status |
|---|-----|------|-----|-----|--------|
| 1 | KL-01 | component | store | Redux | FAIL |
| 2 | KL-02 | route | page | Router | PASS |
?+ === VERIFICATION HISTORY ===
?< Widget accuracy>>FAIL
?< docs/api.md>>FAIL
?< Redux>>FAIL
?h- PASS
== six-column-fail-text-outside-status-column-is-ignored
@plan 03-01-PLAN.md|01|Test plan|
@sum 03-01-SUMMARY.md|complete|Feature
@v 03-VERIFICATION.md|PASS
@h Artifact Checks
| %N | ID | Artifact | Exists | Contains | Status |
|---|-----|----------|--------|----------|--------|
| 1 | ART-01 | docs/api.md | Yes | Contains FAIL example | PASS |
| 2 | ART-02 | docs/guide.md | Yes | Stable output | PASS |
?+ === VERIFICATION HISTORY ===
?h- Contains FAIL example
== round-two-uses-previous-round-verification
@stage qa|verify|02
@plan 03-01-PLAN.md|01|Original phase plan|Original requirement
@sum 03-01-SUMMARY.md|complete|Original build
@vt 03-VERIFICATION.md|FAIL
@row PH-01|Phase-level fail|FAIL|Missing
@vt remediation/qa/round-01/R01-VERIFICATION.md|FAIL
@row R1-01|Round-one fail|FAIL|Still broken
@round qa|02|Round two remediation|complete|Implemented another fix attempt|Fix round one fail
?f --remediation-only
?+ verify_scope=remediation round=02
?+ FAIL_ID: R1-01 | ORIGINAL: Round-one fail
?- FAIL_ID: PH-01 | ORIGINAL: Phase-level fail
== round-two-without-previous-round-verification-marks-source-missing
@stage qa|verify|02
@plan 03-01-PLAN.md|01|Original phase plan|Original requirement
@sum 03-01-SUMMARY.md|complete|Original build
@vt 03-VERIFICATION.md|FAIL
@row PH-01|Phase-level fail|FAIL|Missing
@round qa|02|Round two remediation|complete|Implemented another fix attempt|Fix round one fail
?f --remediation-only
?+ --- ORIGINAL FAIL RESOLUTION STATUS ---
?+ source_verification_missing=true
?- FAIL_ID: PH-01 | ORIGINAL: Phase-level fail
== round-two-falls-back-to-phase-verification-after-structural-pass
@stage qa|verify|02
@plan 03-01-PLAN.md|01|Original phase plan|Original requirement
@sum 03-01-SUMMARY.md|complete|Original build
@vt 03-VERIFICATION.md|FAIL
@row PH-01|Phase-level fail|FAIL|Missing
@vt remediation/qa/round-01/R01-VERIFICATION.md|PASS
@row MH-01|Structural bookkeeping passed|PASS|Done
@round qa|02|Round two remediation|complete|Documented the next remediation attempt|Carry forward unresolved original fail
?f --remediation-only
?+ verify_scope=remediation round=02
?+ FAIL_ID: PH-01 | ORIGINAL: Phase-level fail
?- source_verification_missing=true
== pass-only-phase-verification-marks-source-missing
@stage qa|verify|02
@vt 03-VERIFICATION.md|PASS
@row MH-01|Structural bookkeeping passed|PASS|Done
@vt remediation/qa/round-01/R01-VERIFICATION.md|PASS
@row MH-01|Structural bookkeeping passed|PASS|Done
@round qa|02|Round two remediation|complete|Documented the next remediation attempt|Missing carried-forward FAILs must fail closed
?f --remediation-only
?+ --- ORIGINAL FAIL RESOLUTION STATUS ---
?+ source_verification_missing=true
?- FAIL_ID:
== missing-phase-verification-after-structural-pass-marks-source-missing
@stage qa|verify|02
@vt remediation/qa/round-01/R01-VERIFICATION.md|PASS
@row MH-01|Structural bookkeeping passed|PASS|Done
@round qa|02|Round two remediation|complete|Documented the missing source verification problem|Source verification must still exist
?f --remediation-only
?+ --- ORIGINAL FAIL RESOLUTION STATUS ---
?+ source_verification_missing=true
?- FAIL_ID:
== round-one-without-phase-verification-marks-source-missing
@stage qa|verify|01
@round qa|01|Round one remediation|complete|Implemented first remediation attempt|Fix original fail
?f --remediation-only
?+ --- ORIGINAL FAIL RESOLUTION STATUS ---
?+ source_verification_missing=true
== truth-condition-header-lists-fail-rows-only
@plan 03-01-PLAN.md|01|Test plan|Item one
@sum 03-01-SUMMARY.md|complete|Feature A
@v 03-VERIFICATION.md|FAIL
@h Must-Have Checks
| ID | Category | Truth/Condition | Status | Evidence |
|----|----------|-----------------|--------|----------|
| MH-01 | must_have | API returns JSON | FAIL | Returns XML |
| MH-02 | must_have | Widget renders | PASS | Confirmed |
| MH-03 | must_have | Tests pass | FAIL | 2 failures |
?+ --- ORIGINAL FAIL RESOLUTION STATUS ---
?+ FAIL_ID: MH-01
?+ FAIL_ID: MH-03
?- FAIL_ID: MH-02
?+ API returns JSON
?+ Tests pass
?+ RESOLUTION_REQUIRED: code-fix, plan-amendment, or documented process-exception
== pass-only-verification-emits-no-fail-ids
@plan 03-01-PLAN.md|01|Test plan|Item one
@sum 03-01-SUMMARY.md|complete|Feature A
@v 03-VERIFICATION.md|PASS
@h Must-Have Checks
| ID | Category | Truth/Condition | Status | Evidence |
|----|----------|-----------------|--------|----------|
| MH-01 | must_have | API returns JSON | PASS | Confirmed |
| MH-02 | must_have | Widget renders | PASS | Done |
?+ --- ORIGINAL FAIL RESOLUTION STATUS ---
?- FAIL_ID:
== description-column-header
@plan 03-01-PLAN.md|01|Test plan|Item one
@sum 03-01-SUMMARY.md|complete|Feature A
@vt 03-VERIFICATION.md|FAIL
@row MH-01|Login works|FAIL|401 error
@row MH-02|Logout works|PASS|Done
?+ FAIL_ID: MH-01
?+ Login works
?- FAIL_ID: MH-02
== link-column-header-fallback
@plan 03-01-PLAN.md|01|Test plan|Item one
@sum 03-01-SUMMARY.md|complete|Feature A
@v 03-VERIFICATION.md|FAIL
@h Key Link Checks
| %N | ID | Link | Status | Evidence |
|---|-----|------|--------|----------|
| 1 | KL-01 | qa-result-gate.sh → vibe.md routing | FAIL | Routing drift |
| 2 | KL-02 | qa-result-gate.sh → execute-protocol.md routing | PASS | Aligned |
?+ FAIL_ID: KL-01
?+ qa-result-gate.sh → vibe.md routing
?- FAIL_ID: KL-02
== no-phase-verification-emits-no-status-block
@plan 03-01-PLAN.md|01|Test plan|Item one
@sum 03-01-SUMMARY.md|complete|Feature A
?- --- ORIGINAL FAIL RESOLUTION STATUS ---
== rows-without-id-column-get-synthesized-ids
@plan 03-01-PLAN.md|01|Test plan|Item one
@sum 03-01-SUMMARY.md|complete|Feature A
@v 03-VERIFICATION.md|FAIL
@h Checks
| Category | Description | Status | Evidence |
|----------|-------------|--------|----------|
| must_have | Legacy brownfield failure | FAIL | Missing |
?+ FAIL_ID: FAIL-ROW-01 | ORIGINAL: Legacy brownfield failure
== multi-table-verification-lists-fails-from-every-table
@plan 03-01-PLAN.md|01|Test plan|API works
@sum 03-01-SUMMARY.md|complete|Feature A
@v 03-VERIFICATION.md|FAIL
@h Must-Have Checks
| ID | Category | Truth/Condition | Status | Evidence |
|----|----------|-----------------|--------|----------|
| MH-01 | must_have | API returns JSON | FAIL | Returns XML |
| MH-02 | must_have | Auth works | PASS | Done |
@h Artifact Checks
| %N | ID | Artifact | Exists | Key Link | Status |
|---|-----|----------|--------|----------|--------|
| 1 | ART-01 | docs/api.md | Yes | - | PASS |
| 2 | ART-02 | docs/deploy.md | No | - | FAIL |
?+ --- ORIGINAL FAIL RESOLUTION STATUS ---
?+ FAIL_ID: MH-01
?+ API returns JSON
?+ FAIL_ID: ART-02
?- FAIL_ID: MH-02
?- FAIL_ID: ART-01
CASES
}
