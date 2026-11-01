#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  reset_case_failures
  STATE_SCRIPT="$SCRIPTS_DIR/uat-remediation-state.sh"
  TEST_ROOT="$TEST_TEMP_DIR/repo"
  mkdir -p "$TEST_ROOT"
  cd "$TEST_ROOT" || return 1
  TEST_ROOT=$(pwd -P)
  git init -q
}

teardown() {
  cd "$BATS_TEST_DIRNAME" || true
  teardown_temp_dir
}

fresh_phase() {
  PHASE_DIR="$TEST_ROOT/$1/.lbwc-planning/phases/01-checkout"
  ROUND_STATE="$PHASE_DIR/remediation/uat/.uat-remediation-stage"
  PHASE_STATE="$PHASE_DIR/.uat-remediation-stage"
  REMED_STATE="$PHASE_DIR/remediation/.uat-remediation-stage"
  mkdir -p "$PHASE_DIR"
}

write_lines() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

write_uat() {
  write_lines "$1" '---' "status: $2" "phase: \"01\"" '---' '### P1 Checkout' "- **Result:** issue"
}

state() {
  run bash "$STATE_SCRIPT" "$1" "$PHASE_DIR" "${2:-}"
}

@test "uat-remediation-state get, current-round and reset read and clear the stage in every state layout" {
  fresh_phase get-none
  state get
  expect_case get-none 0 none

  fresh_phase get-legacy-keyed
  write_lines "$PHASE_STATE" stage=execute round=02
  state get
  expect_case get-legacy-keyed 0 execute
  state current-round
  expect_case get-legacy-keyed-round 0 02

  fresh_phase get-legacy-bare
  write_lines "$PHASE_STATE" fix
  state get
  expect_case get-legacy-bare 0 fix

  fresh_phase migrates-remediation-state
  write_lines "$REMED_STATE" stage=plan round=01 layout=round-dir
  write_uat "$PHASE_DIR/remediation/round-01/R01-UAT.md" issues_found
  state get
  expect_case migrates-remediation-state 0 plan
  expect_path migrates-remediation-state "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"
  expect_no_path migrates-remediation-state "$REMED_STATE"
  expect_file_line migrates-remediation-state "$ROUND_STATE" '^stage=plan$'

  fresh_phase round-explicit
  write_lines "$ROUND_STATE" stage=plan round=03 layout=round-dir
  state current-round
  expect_case round-explicit 0 03

  fresh_phase round-legacy-inferred
  write_lines "$ROUND_STATE" stage=plan round=01 layout=legacy
  write_uat "$PHASE_DIR/01-UAT-round-02.md" issues_found
  state current-round
  expect_case round-legacy-inferred 0 03

  fresh_phase round-legacy-stored
  write_lines "$ROUND_STATE" stage=plan round=04 layout=legacy
  state current-round
  expect_case round-legacy-stored 0 04

  fresh_phase round-no-state
  state current-round
  expect_case round-no-state 0 01

  fresh_phase reset
  write_lines "$ROUND_STATE" stage=plan round=01 layout=round-dir
  write_lines "$PHASE_STATE" stage=plan
  state reset
  expect_case reset 0 none
  expect_no_path reset "$ROUND_STATE"
  expect_no_path reset "$PHASE_STATE"

  run bash "$STATE_SCRIPT" reset "$TEST_ROOT/reset/.lbwc-planning/phases/07-gone"
  expect_case reset-missing-phase 0 none
  expect_no_path reset-missing-phase "$TEST_ROOT/reset/.lbwc-planning/phases/07-gone"

  assert_no_case_failures
}

@test "uat-remediation-state accepts only active phase directories and known commands" {
  fresh_phase relative
  write_lines "$ROUND_STATE" stage=execute round=01 layout=round-dir
  run bash "$STATE_SCRIPT" get relative/.lbwc-planning/phases/01-checkout
  expect_case relative-path 0 execute

  run bash "$STATE_SCRIPT" get "$TEST_ROOT/relative/.lbwc-planning/phases/09-new"
  expect_case missing-phase-with-parent 0 none

  run bash "$STATE_SCRIPT" get "$TEST_ROOT/nowhere/.lbwc-planning/phases/01-x"
  expect_case missing-parent 0 none

  run bash "$STATE_SCRIPT" get "$TEST_ROOT/x/.lbwc-planning/milestones/m1/phases/01-old"
  expect_case milestone 1 "refusing to operate on archived milestone path"

  mkdir -p "$TEST_ROOT/plain/01-checkout"
  run bash "$STATE_SCRIPT" get "$TEST_ROOT/plain/01-checkout"
  expect_case outside-phases 1 "must be under active .lbwc-planning/phases/"

  run bash "$STATE_SCRIPT" get
  expect_case missing-phase-arg 1 "Usage: uat-remediation-state.sh"

  run bash "$STATE_SCRIPT" rewind "$PHASE_DIR"
  expect_case unknown-command 1 "Unknown command: rewind"

  assert_no_case_failures
}

@test "uat-remediation-state advance walks the major and minor stage ladders and opens a new round after verify" {
  fresh_phase from-research
  write_lines "$ROUND_STATE" stage=research round=01 layout=round-dir
  write_lines "$PHASE_STATE" stage=research
  state advance
  expect_case from-research 0 plan
  expect_file_line from-research "$ROUND_STATE" '^stage=plan$'
  expect_file_line from-research "$ROUND_STATE" '^round=01$'
  expect_no_path from-research "$PHASE_STATE"

  fresh_phase from-execute
  write_lines "$ROUND_STATE" stage=execute round=02 layout=legacy
  state advance
  expect_case from-execute 0 done
  expect_file_line from-execute "$ROUND_STATE" '^layout=legacy$'

  fresh_phase from-fix
  write_lines "$ROUND_STATE" stage=fix round=01 layout=round-dir
  state advance
  expect_case from-fix 0 done

  fresh_phase from-done
  write_lines "$ROUND_STATE" stage=done round=01 layout=round-dir
  state advance
  expect_case from-done 0 verify

  fresh_phase from-unknown
  write_lines "$ROUND_STATE" stage=drafting round=01 layout=round-dir
  state advance
  expect_case from-unknown 0 done

  fresh_phase from-verify
  write_lines "$ROUND_STATE" stage=verify round=01 layout=round-dir
  state advance
  expect_case from-verify 0 "round=02"
  expect_output_has from-verify "summary_path=$PHASE_DIR/remediation/uat/round-02/R02-SUMMARY.md"
  expect_file_line from-verify "$ROUND_STATE" '^stage=research$'
  expect_path from-verify "$PHASE_DIR/remediation/uat/round-02"

  fresh_phase verified-stays
  write_lines "$ROUND_STATE" stage=verified round=01 layout=round-dir
  state advance
  expect_case verified-stays 0 verified

  fresh_phase none-stays
  state advance
  expect_case none-stays 0 none
  expect_no_path none-stays "$ROUND_STATE"

  assert_no_case_failures
}

@test "uat-remediation-state needs-round opens the next round only after a finalized issues_found UAT" {
  fresh_phase legacy-remediation
  write_lines "$REMED_STATE" stage=verify round=01 layout=round-dir
  write_uat "$PHASE_DIR/remediation/round-01/R01-UAT.md" issues_found
  state needs-round
  expect_case legacy-remediation 0 "round=02"
  expect_path legacy-remediation "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md"
  expect_file_line legacy-remediation "$ROUND_STATE" '^round=02$'

  fresh_phase legacy-bare-stage
  write_lines "$REMED_STATE" research
  state needs-round
  expect_case legacy-bare-stage 1 "requires stage verify or done, got: research"

  fresh_phase legacy-bad-round
  write_lines "$REMED_STATE" stage=done round=x1
  state needs-round
  expect_case legacy-bad-round 1 "invalid UAT remediation round value: x1"

  fresh_phase legacy-missing-uat
  write_lines "$REMED_STATE" stage=done
  state needs-round
  expect_case legacy-missing-uat 1 "UAT evidence is missing for round 01"

  fresh_phase round-dir-complete-uat
  write_lines "$ROUND_STATE" stage=verify round=01 layout=round-dir
  write_uat "$PHASE_DIR/remediation/uat/round-01/R01-UAT.md" complete
  state needs-round
  expect_case round-dir-complete-uat 1 "current UAT is 'complete'"

  fresh_phase flat-round-uat
  write_lines "$ROUND_STATE" stage=done round=02 layout=round-dir
  write_uat "$PHASE_DIR/01-UAT-round-02.md" issues_found
  state needs-round
  expect_case flat-round-uat 0 "round=03"

  fresh_phase no-state
  state needs-round
  expect_case no-state 1 "no UAT remediation state exists"

  assert_no_case_failures
}

@test "uat-remediation-state init seeds the phase context from the latest UAT in every context shape" {
  fresh_phase new-context
  write_uat "$PHASE_DIR/01-UAT.md" issues_found
  state init critical
  expect_case new-context 0 research
  expect_output_has new-context "---CONTEXT---"
  expect_file_line new-context "$PHASE_DIR/01-CONTEXT.md" '^pre_seeded: true$'
  expect_file_line new-context "$PHASE_DIR/01-CONTEXT.md" '^phase: 01$'

  fresh_phase frontmatter-context
  write_uat "$PHASE_DIR/01-UAT.md" issues_found
  write_lines "$PHASE_DIR/01-CONTEXT.md" '---' 'owner: shop' '---' '# Goals'
  state init minor
  expect_case frontmatter-context 0 fix
  expect_file_line frontmatter-context "$ROUND_STATE" '^stage=fix$'
  expect_file_line frontmatter-context "$PHASE_DIR/01-CONTEXT.md" '^pre_seeded: true$'
  expect_file_line frontmatter-context "$PHASE_DIR/01-CONTEXT.md" '^# Goals$'
  expect_file_line frontmatter-context "$PHASE_DIR/01-CONTEXT.md" '^## UAT Remediation Issues$'

  fresh_phase plain-context
  write_uat "$PHASE_DIR/01-UAT.md" issues_found
  write_lines "$PHASE_DIR/01-CONTEXT.md" '# Goals only'
  state init major
  expect_case plain-context 0 research
  expect_file_line plain-context "$PHASE_DIR/01-CONTEXT.md" '^pre_seeded: true$'
  expect_file_line plain-context "$PHASE_DIR/01-CONTEXT.md" '^# Goals only$'

  fresh_phase reseeded-context
  write_uat "$PHASE_DIR/01-UAT.md" issues_found
  write_lines "$PHASE_DIR/01-CONTEXT.md" '---' 'pre_seeded: true' '---' '# Goals' '## UAT Remediation Issues' 'stale issue text'
  state init major
  expect_case reseeded-context 0 research
  expect_no_file_line reseeded-context "$PHASE_DIR/01-CONTEXT.md" 'stale issue text'
  expect_file_line reseeded-context "$PHASE_DIR/01-CONTEXT.md" '^### P1 Checkout$'

  fresh_phase no-uat
  state init blocker
  expect_case no-uat 0 research
  expect_output_lacks no-uat "---CONTEXT---"
  expect_no_path no-uat "$PHASE_DIR/01-CONTEXT.md"

  state init
  expect_case missing-severity 1 "Usage: uat-remediation-state.sh init"

  assert_no_case_failures
}

@test "uat-remediation-state get-or-init resumes existing state, adopts a legacy phase file, or initializes" {
  fresh_phase resume-round-dir
  write_lines "$ROUND_STATE" stage=plan round=02 layout=round-dir
  write_lines "$PHASE_DIR/remediation/uat/round-02/R02-PLAN.md" '# plan'
  write_lines "$PHASE_DIR/remediation/uat/round-02/R02-RESEARCH.md" '# research'
  state get-or-init major
  expect_output_has resume-round-dir "research_path=$PHASE_DIR/remediation/uat/round-02/R02-RESEARCH.md"
  expect_case resume-round-dir 0 plan
  expect_output_has resume-round-dir "plan_path=$PHASE_DIR/remediation/uat/round-02/R02-PLAN.md"
  expect_output_lacks resume-round-dir "---CONTEXT---"

  fresh_phase adopt-legacy
  write_lines "$PHASE_STATE" stage=execute
  write_lines "$PHASE_DIR/01-02-RESEARCH.md" '# research'
  write_lines "$PHASE_DIR/01-03-PLAN.md" '# plan'
  state get-or-init major
  expect_case adopt-legacy 0 execute
  expect_output_has adopt-legacy "research_path=$PHASE_DIR/01-02-RESEARCH.md"
  expect_output_has adopt-legacy "plan_path=$PHASE_DIR/01-03-PLAN.md"
  expect_file_line adopt-legacy "$ROUND_STATE" '^layout=legacy$'
  expect_no_path adopt-legacy "$PHASE_STATE"

  fresh_phase legacy-phase-research
  write_lines "$ROUND_STATE" stage=research round=01 layout=legacy
  write_lines "$PHASE_DIR/01-RESEARCH.md" '# research'
  state get-or-init major
  expect_case legacy-phase-research 0 "research_path=$PHASE_DIR/01-RESEARCH.md"
  expect_output_has legacy-phase-research "plan_path="

  fresh_phase initializes
  write_uat "$PHASE_DIR/01-UAT.md" issues_found
  state get-or-init minor
  expect_case initializes 0 fix
  expect_output_has initializes "round_dir=$PHASE_DIR/remediation/uat/round-01"
  expect_output_has initializes "---CONTEXT---"

  state get-or-init
  expect_case missing-severity 1 "Usage: uat-remediation-state.sh get-or-init"

  assert_no_case_failures
}
