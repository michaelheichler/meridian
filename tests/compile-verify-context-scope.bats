#!/usr/bin/env bats

load test_helper
load compile_verify_helper

setup() {
  cvc_setup
}

teardown() {
  teardown_temp_dir
}

@test "compile-verify-context selects the plans, round, header, and uat_path for each scope" {
  cvc_run_cases <<'CASES'
== remediation-only-completed-round-emits-only-round-plans
@plan 03-01-PLAN.md|01|Original login form|Email field validates format
@sum 03-01-SUMMARY.md|complete|Login form|src/login.tsx
@round uat|01|Fix validation bug|complete|Fixed email regex|Email validation no longer rejects valid addresses
?f --remediation-only
?+ verify_scope=remediation round=01
?+ === PLAN R01: Fix validation bug ===
?+ Email validation no longer rejects valid addresses
?- Original login form
?+ verify_plan_count=1
== remediation-only-picks-latest-completed-round
@round uat|01|Round 1 fix|complete|Round 1 work|Old fix
@round uat|02|Round 2 fix|complete|Round 2 work|Latest fix
?f --remediation-only
?+ verify_scope=remediation round=02
?+ === PLAN R02: Round 2 fix ===
?+ Latest fix
?- Round 1 fix
?+ verify_plan_count=1
== remediation-only-skips-round-with-in-progress-summary
@round uat|01|Round 1 fix|complete|Round 1 work|Old fix
@round uat|02|Round 2 fix|in-progress|Round 2 work|Latest fix
?f --remediation-only
?+ verify_scope=remediation round=01
?+ Round 1 fix
?- Round 2 fix
== remediation-only-accepts-partial-status-as-terminal
@round uat|01|Partial round|partial|Partial work|Partial fix
?f --remediation-only
?+ verify_scope=remediation round=01
?+ Partial round
== remediation-only-accepts-failed-status-as-terminal
@round uat|01|Failed round|failed|Nothing|Failed fix
?f --remediation-only
?+ verify_scope=remediation round=01
?+ Failed round
== active-qa-stage-beats-stale-higher-round
@stage qa|verify|01
@round qa|01|Active round one|complete|Round 1 work|Fix current issue
@round qa|02|Stale higher round|complete|Round 2 stale work|Old stale issue
?f --remediation-only
?+ verify_scope=remediation round=01
?+ === PLAN R01: Active round one ===
?- Stale higher round
== active-qa-stage-beats-stale-uat-history
@plan 03-01-PLAN.md|01|Root plan|
@sum 03-01-SUMMARY.md|complete|Root feature
@round uat|01|Old UAT remediation|complete|Old UAT fix|
@stage qa|done|02
@round qa|02|Current QA remediation|complete|Current QA fix|
?f --remediation-only
?+ verify_scope=remediation round=02
?+ === PLAN R02: Current QA remediation ===
?- === PLAN R01: Old UAT remediation ===
?+ uat_path=03-UAT.md
== active-uat-round-08-keeps-remediation-scope-without-octal-error
@plan 03-01-PLAN.md|01|Phase-root plan|Original feature remains out of remediation scope
@stage uat|verify|08|round-dir
@round uat|08|Round 8 UAT remediation|complete|Fixed the round-eight UAT issue|Round-eight UAT issue fixed
?f --remediation-only --remediation-kind uat
?- invalid number
?+ verify_scope=remediation round=08
?+ uat_path=remediation/uat/round-08/R08-UAT.md
?+ === PLAN R08: Round 8 UAT remediation ===
?- Phase-root plan
?+ verify_plan_count=1
== active-uat-stage-prefers-current-round-over-stale-completed-round
@stage uat|plan|02|round-dir
@round uat|01|Previous round fix|complete|Previous round fix|Previous round issue fixed
@round uat|02|Current round fix|||Current round issue fixed
?f --remediation-only --remediation-kind uat
?+ verify_scope=remediation round=02
?+ uat_path=remediation/uat/round-02/R02-UAT.md
?+ === PLAN R02: Current round fix ===
?- === PLAN R01: Previous round fix ===
?+ status: no_summary
== remediation-only-falls-back-to-qa-rounds-without-stage
@plan 03-01-PLAN.md|01|Root plan|
@sum 03-01-SUMMARY.md|complete|Root feature
@round qa|01|QA remediation round|complete|Remediation fix|
?f --remediation-only
?+ verify_scope=remediation round=01
?+ === PLAN R01: QA remediation round ===
?- === PLAN 01: Root plan ===
?+ uat_path=03-UAT.md
== remediation-only-prefers-uat-round-over-qa-round-without-stage
@plan 03-01-PLAN.md|01|Original feature|Feature works
@sum 03-01-SUMMARY.md|complete|Thing
@round uat|01|Fix UAT issues|complete|Fixed UAT issue|UAT issue fixed
@round qa|01|Fix QA deviations|complete|Fixed deviation|Deviation resolved
?f --remediation-only
?+ verify_scope=remediation
?+ verify_plan_count=1
?+ Fix UAT issues
?- Fix QA deviations
== remediation-only-includes-every-plan-of-the-qa-round
@stage qa|verify|01
@round qa|01|First remediation plan|complete|Reimplemented the API layer|Fix first issue
@plan remediation/qa/round-01/R01-02-PLAN.md|R01-02|Second remediation plan|Fix second issue
?f --remediation-only
?+ === PLAN R01: First remediation plan ===
?+ === PLAN R01-02: Second remediation plan ===
?< === PLAN R01-02: Second remediation plan ===>>status: complete
?< === PLAN R01-02: Second remediation plan ===>>Reimplemented the API layer
?+ verify_plan_count=2
== remediation-only-with-uat-round-emits-round-dir-uat-path
@round uat|01|Round 1 remediation|complete|Fixed things|Fix the issue
?f --remediation-only
?+ uat_path=remediation/uat/round-01/R01-UAT.md
== remediation-only-with-legacy-layout-emits-legacy-uat-path
@round legacy|01|Legacy round 1|complete|Fixed things|Fix legacy issue
?f --remediation-only
?+ uat_path=remediation/round-01/R01-UAT.md
?+ verify_scope=remediation round=01
== remediation-only-without-completed-round-falls-back-to-full
@plan 03-01-PLAN.md|01|Original plan|Something
@round uat|01|Incomplete round|||Unfinished
?f --remediation-only
?+ verify_scope=full
?+ Original plan
?+ Incomplete round
?+ uat_path=03-UAT.md
== remediation-only-with-empty-remediation-dir-falls-back-to-full
@plan 03-01-PLAN.md|01|Some plan|Feature
@dir remediation/uat
?f --remediation-only
?+ verify_scope=full
?+ Some plan
== full-scope-header-and-uat-path-use-phase-number
@plan 03-01-PLAN.md|01|Basic plan|Something
?^ verify_scope=full
?+ uat_path=03-UAT.md
== full-scope-includes-phase-root-and-uat-remediation-plans
@plan 03-01-PLAN.md|01|Phase-root plan|Original feature
@round uat|01|Remediation plan|||Fix something
?+ verify_scope=full
?+ Phase-root plan
?+ Remediation plan
?+ verify_plan_count=2
== full-scope-discovers-qa-remediation-plans
@plan 03-01-PLAN.md|01|Original feature|Feature works
@sum 03-01-SUMMARY.md|complete|The feature|src/feature.swift
@round qa|01|Fix QA deviations|complete|Fixed the deviation|Deviation resolved
?+ verify_plan_count=2
?+ === PLAN 01: Original feature ===
?+ === PLAN R01: Fix QA deviations ===
== full-scope-discovers-root-uat-and-qa-plans
@plan 03-01-PLAN.md|01|Original feature|Feature works
@sum 03-01-SUMMARY.md|complete|The feature
@round uat|01|Fix UAT issues|complete|Fixed UAT|UAT fixed
@round qa|01|Fix QA deviations|complete|Fixed QA deviation|QA fixed
?+ verify_scope=full
?+ verify_plan_count=3
?+ Original feature
?+ Fix UAT issues
?+ Fix QA deviations
CASES
}

@test "compile-verify-context rejects a missing or invalid remediation kind" {
  cvc_run_cases <<'CASES'
== invalid-kind-value
?f --remediation-only --remediation-kind invalid
?s 1
?+ must be 'qa' or 'uat'
== equals-form-with-empty-value
?f --remediation-only --remediation-kind=
?s 1
?+ requires a value
== separate-form-with-quoted-empty-value
?f --remediation-only --remediation-kind EMPTY
?s 1
?+ requires a value
== next-argument-is-an-option
?f --remediation-kind --remediation-only
?s 1
?+ requires a value
CASES
}

@test "compile-verify-context limits remediation rounds to the requested kind" {
  cvc_run_cases <<'CASES'
== kind-uat-skips-qa-when-both-dirs-exist
@plan 03-01-PLAN.md|01|Root plan|
@sum 03-01-SUMMARY.md|complete|Root feature
@stage qa|done|01
@round qa|01|QA fix|complete|QA fix|
@stage uat|verify|01
@round uat|01|UAT fix|complete|UAT fix|
?f --remediation-only
?+ uat_path=03-UAT.md
?run --remediation-only --remediation-kind uat
?+ verify_scope=remediation round=01
?+ uat_path=remediation/uat/round-01/R01-UAT.md
?+ === PLAN R01: UAT fix ===
?- === PLAN R01: QA fix ===
== kind-qa-filters-to-qa-only
@plan 03-01-PLAN.md|01|Root plan|
@sum 03-01-SUMMARY.md|complete|Root feature
@stage qa|done|01
@round qa|01|QA fix|complete|QA fix|
@stage uat|verify|01
@round uat|01|UAT fix|complete|UAT fix|
?f --remediation-only --remediation-kind qa
?+ verify_scope=remediation round=01
?+ uat_path=03-UAT.md
?+ === PLAN R01: QA fix ===
?- === PLAN R01: UAT fix ===
== kind-qa-does-not-fall-back-to-legacy-rounds
@plan 03-01-PLAN.md|01|Root plan|Root feature works
@sum 03-01-SUMMARY.md|complete|Root feature
@round legacy|01|Legacy remediation|complete|Legacy fix|Legacy fix
?f --remediation-only --remediation-kind qa
?+ verify_scope=full
?+ uat_path=03-UAT.md
?- verify_scope=remediation round=01
== kind-uat-still-supports-legacy-rounds
@round legacy|01|Legacy remediation|complete|Legacy fix|Legacy fix
?f --remediation-only --remediation-kind uat
?+ verify_scope=remediation round=01
?+ uat_path=remediation/round-01/R01-UAT.md
CASES
}
