#!/usr/bin/env bats

load test_helper
load compile_verify_helper

setup() {
  cvc_setup
}

teardown() {
  teardown_temp_dir
}

@test "compile-verify-context renders plan records from plan and summary files" {
  cvc_run_cases <<'CASES'
== multi-plan-with-summaries
@plan 03-01-PLAN.md|01|Add login form|Email field validates format;;Password field has minimum length
@sum 03-01-SUMMARY.md|complete|Login form component with email/password fields|src/components/LoginForm.tsx
@plan 03-02-PLAN.md|02|Add auth API endpoint|POST /api/auth returns JWT;;Invalid credentials return 401
@sum 03-02-SUMMARY.md|complete|POST /api/auth endpoint|src/api/auth.ts
?+ === PLAN 01: Add login form ===
?+ must_haves: Email field validates format; Password field has minimum length
?+ Login form component
?+ src/components/LoginForm.tsx
?+ status: complete
?+ === PLAN 02: Add auth API endpoint ===
?+ POST /api/auth returns JWT
?+ src/api/auth.ts
?+ verify_plan_count=2
== plan-without-summary-shows-no-summary
@plan 03-01-PLAN.md|01|Incomplete plan|Something important
?+ === PLAN 01: Incomplete plan ===
?+ status: no_summary
?+ what_was_built: none
?+ files_modified: none
?+ verify_plan_count=1
== no-summary-plan-does-not-inherit-prior-summary-state
@plan 03-01-PLAN.md|01|Complete plan|First plan complete
@ 03-01-SUMMARY.md
---
status: complete
deviations:
  - Prior plan deviation should stay local
pre_existing_issues:
  - '{"test":"PriorSuite","file":"Tests/PriorSuite.swift","error":"prior failure should stay local"}'
---
## What Was Built
- First plan complete
@plan 03-02-PLAN.md|02|No summary plan|Second plan still pending
?+ Prior plan deviation should stay local
?+ pre_existing_issues: PriorSuite (Tests/PriorSuite.swift): prior failure should stay local
?in === PLAN 02: No summary plan ===
?+ status: no_summary
?+ deviations: none
?+ summary_deviation_reviews: none
?+ pre_existing_issues: none
?- Prior plan deviation should stay local
?- prior failure should stay local
== legacy-plan-and-summary-files
@plan PLAN.md|01|Legacy plan|Legacy path works
@sum SUMMARY.md|complete|Legacy phase artifact support|src/legacy.ts
?+ === PLAN 01: Legacy plan ===
?+ Legacy phase artifact support
?+ src/legacy.ts
?+ verify_plan_count=1
== empty-dir-returns-empty-marker
?= verify_context=empty
== nonexistent-dir-returns-error-marker
?f NOPHASE
?= verify_context_error=no_phase_dir
== what-was-built-limited-to-five-lines
@plan 03-01-PLAN.md|01|Big plan|Feature delivered
@ 03-01-SUMMARY.md
---
status: complete
---
## What Was Built
- Item one
- Item two
- Item three
- Item four
- Item five
- Item six should not appear
- Item seven should not appear
## Files Modified
- `src/a.ts` -- modified: something
?+ Item five
?- Item six
?- Item seven
== must-haves-nested-truths-and-artifacts
@ 03-01-PLAN.md
---
plan: 01
title: Structured must_haves
must_haves:
  truths:
    - "Invariant one holds"
    - "Invariant two holds"
  artifacts:
    - {path: "src/foo.ts", provides: "module", contains: "export"}
---
?+ Invariant one holds
?+ Invariant two holds
?+ src/foo.ts
== pre-existing-issues-from-summary-frontmatter
@plan 03-01-PLAN.md|01|Frontmatter pre-existing issues|Something
@ 03-01-SUMMARY.md
---
status: complete
pre_existing_issues:
  - '{"test":"TransferMatchingServiceTests","file":"Tests/TransferMatchingServiceTests.swift","error":"debugTestConfiguration missing"}'
---
## What Was Built
- Thing
?+ pre_existing_issues: TransferMatchingServiceTests (Tests/TransferMatchingServiceTests.swift): debugTestConfiguration missing
== empty-frontmatter-pre-existing-issues-suppress-body-fallback
@plan 03-01-PLAN.md|01|Empty frontmatter pre-existing issues|Something
@ 03-01-SUMMARY.md
---
status: complete
pre_existing_issues: []
---
## What Was Built
- Thing
## Pre-existing Issues
- GhostIssueTests.swift: stale body issue must be ignored
?+ pre_existing_issues: none
?- GhostIssueTests.swift
== plan-id-falls-back-to-round-file-name
@plan remediation/qa/round-02/R02-PLAN.md||Second QA fix round|All checks pass
@sum remediation/qa/round-02/R02-SUMMARY.md|complete|Fixed remaining issues
?+ === PLAN R02: Second QA fix round ===
?+ status: complete
== remediation-summary-aggregates-task-sections
@plan remediation/qa/round-01/R01-PLAN.md|R01|Multi-task remediation|Fix both issues
@ remediation/qa/round-01/R01-SUMMARY.md
---
status: complete
files_modified:
  - src/api.swift
  - src/ui.swift
deviations: []
---
## Task 1: Update API layer
### What Was Built
- Reimplemented the API layer
### Files Modified
- `src/api.swift` -- rewritten
## Task 2: Update UI layer
### What Was Built
- Adjusted the remediation UI flow
### Files Modified
- `src/ui.swift` -- rewritten
?+ Reimplemented the API layer
?+ Adjusted the remediation UI flow
CASES
}

@test "compile-verify-context extracts summary deviations from every supported shape" {
  cvc_run_cases <<'CASES'
== flow-style-yaml-deviations
@plan 03-01-PLAN.md|01|Flow deviations|Feature delivered
@ 03-01-SUMMARY.md
---
status: complete
deviations: ["Changed API contract", 'Moved tests to existing file']
---
## What Was Built
- Feature delivered
## Files Modified
- `src/feature.ts` -- modified: implement feature
?+ deviations: Changed API contract; Moved tests to existing file
== body-deviations-when-frontmatter-has-none
@plan 03-01-PLAN.md|01|Model with deviation|Feature works
@ 03-01-SUMMARY.md
---
status: complete
---
## What Was Built
- The model
## Deviations
- **Uniqueness test approach**: Changed from raw constraint test to upsert pattern test
- **Started before dependency completed**: Proceeded since API was on disk
?+ deviations: Changed from raw constraint test to upsert pattern test; Proceeded since API was on disk
== body-deviations-none-sentence-means-no-deviations
@plan 03-01-PLAN.md|01|No deviations|Something
@ 03-01-SUMMARY.md
---
status: complete
---
## What Was Built
- Thing
## Deviations
None. All tasks implemented as specified.
?+ deviations: none
== body-deviations-bold-none-is-filtered
@plan 03-01-PLAN.md|01|Bold none|Something
@ 03-01-SUMMARY.md
---
status: complete
---
## What Was Built
- Thing
## Deviations
- **None**: No deviations from plan
?+ deviations: none
== body-deviations-bold-n-a-with-explanation-is-filtered
@plan 03-01-PLAN.md|01|Bold NA|Something
@ 03-01-SUMMARY.md
---
status: complete
---
## What Was Built
- Thing
## Deviations
- **N/A**: not applicable
?+ deviations: none
== qa-summary-frontmatter-deviations-and-task-sections
@plan remediation/qa/round-01/R01-PLAN.md|R01|Fix deviations|API matches spec
@ remediation/qa/round-01/R01-SUMMARY.md
---
status: complete
files_modified:
  - src/api.swift
deviations:
  - "Used different endpoint naming"
---
## Task 1: Update API layer
### What Was Built
- Reimplemented the API layer
### Files Modified
- `src/api.swift` -- rewritten
?+ Reimplemented the API layer
?+ deviations: Used different endpoint naming
?+ files_modified: src/api.swift
== task-level-bullet-deviations
@plan remediation/qa/round-01/R01-PLAN.md|R01|Task-level deviation extraction|API matches spec
@ remediation/qa/round-01/R01-SUMMARY.md
---
status: complete
files_modified:
  - src/api.swift
deviations: []
---
## Task 1: Update API layer
### What Was Built
- Reimplemented the API layer
### Deviations
- Used a different helper function than planned
?+ deviations: Used a different helper function than planned
== task-level-template-comment-is-ignored
@plan remediation/qa/round-01/R01-PLAN.md|R01|Comment-only deviation section|API matches spec
@ remediation/qa/round-01/R01-SUMMARY.md
---
status: complete
files_modified:
  - src/api.swift
deviations: []
---
## Task 1: Update API layer
### What Was Built
- Reimplemented the API layer
### Deviations
@template-comment
?+ deviations: none
== task-level-plain-text-deviation
@plan remediation/qa/round-01/R01-PLAN.md|R01|Plain-text deviation extraction|API matches spec
@ remediation/qa/round-01/R01-SUMMARY.md
---
status: complete
files_modified:
  - src/api.swift
deviations: []
---
## Task 1: Update API layer
### What Was Built
- Reimplemented the API layer
### Deviations
Used a different helper function than planned
?+ deviations: Used a different helper function than planned
CASES
}

@test "compile-verify-context surfaces the known issues registry" {
  cvc_run_cases <<'CASES'
== known-issues-block-from-phase-registry
@plan 03-01-PLAN.md|01|Plan with known issues|Something
@sum 03-01-SUMMARY.md|complete|Feature work
@ known-issues.json
{"schema_version":1,"phase":"03","issues":[{"test":"FIGIRegistryServiceTests","file":"Tests/FIGIRegistryServiceTests.swift","error":"compositeFigi missing","first_seen_in":"03-01-SUMMARY.md","last_seen_in":"03-VERIFICATION.md","first_seen_round":0,"last_seen_round":0,"times_seen":2}]}
?+ === KNOWN ISSUES ===
?+ known_issue_count=1
?+ KNOWN_ISSUE: test=FIGIRegistryServiceTests | file=Tests/FIGIRegistryServiceTests.swift | error=compositeFigi missing
== malformed-registry-is-surfaced
@plan 03-01-PLAN.md|01|Plan with malformed registry|Something
@sum 03-01-SUMMARY.md|complete|Feature work
@ known-issues.json
{broken-json
?+ === KNOWN ISSUES ===
?+ known_issues_error=malformed
CASES
}
