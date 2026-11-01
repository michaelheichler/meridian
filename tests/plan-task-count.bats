#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="${PLAN_TASK_COUNT_SCRIPT:-$REPO_ROOT/scripts/plan-task-count.sh}"
  TEST_ROOT="$(mktemp -d)"
  PLAN="$TEST_ROOT/plan fixture.md"
  CONFIG="$TEST_ROOT/config.json"
  cd "$TEST_ROOT"
  reset_case_failures
}

teardown() {
  cd "$REPO_ROOT"
  rm -rf "$TEST_ROOT"
}

write_plan() {
  local records="$1"
  cat > "$PLAN" <<EOF
---
phase: 8
---
<objective>
Prose mentioning <task type="auto"> is not a task record.
</objective>
<tasks>
$records
</tasks>
<verification>
The text <task type="auto"> outside the task block is prose.
</verification>
EOF
}

write_raw_plan() {
  printf '%s\n' "$@" > "$PLAN"
}

NORMALIZE="$BATS_TEST_DIRNAME/../scripts/normalize-plan-filenames.sh"

fresh_dir() {
  DIR="$TEST_ROOT/$1"
  mkdir -p "$DIR"
}

write_round_plan() {
  local file=$1 round=$2 kind=${3:-uat} fields=''
  [ "$kind" != qa ] || fields='known_issues_input: none
known_issue_resolutions: none
'
  cat > "$file" <<EOF
---
phase: 1
round: $round
title: Fix checkout
type: remediation
fail_classifications: none
${fields}---
<tasks>
</tasks>
<verification>
</verification>
EOF
}

@test "normalize-plan-filenames phase dir: renames legacy names without overwriting" {
  fresh_dir renames
  printf 'plan\n' > "$DIR/PLAN-1.md"
  printf 'summary\n' > "$DIR/plan-02-summary.md"
  printf 'context\n' > "$DIR/Plan-3-Context.MD"
  printf 'later summary\n' > "$DIR/SUMMARY-4.md"
  printf 'later context\n' > "$DIR/CONTEXT-5.md"
  run bash "$NORMALIZE" "$DIR/"
  expect_case renames 0 "renamed: PLAN-1.md -> 01-PLAN.md"
  expect_output_has renames "renamed: plan-02-summary.md -> 02-SUMMARY.md"
  expect_output_has renames "renamed: Plan-3-Context.MD -> 03-CONTEXT.md"
  expect_output_has renames "renamed: SUMMARY-4.md -> 04-SUMMARY.md"
  expect_output_has renames "renamed: CONTEXT-5.md -> 05-CONTEXT.md"
  expect_file_line renames "$DIR/01-PLAN.md" '^plan$'
  expect_file_line renames "$DIR/02-SUMMARY.md" '^summary$'
  expect_no_path renames "$DIR/PLAN-1.md"

  fresh_dir existing-target
  printf '# Existing\n' > "$DIR/01-PLAN.md"
  printf '# Source\n' > "$DIR/PLAN-1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case existing-target 0 "skipped: PLAN-1.md (target 01-PLAN.md already exists)"
  expect_file_line existing-target "$DIR/01-PLAN.md" '^# Existing$'
  expect_path existing-target "$DIR/PLAN-1.md"

  fresh_dir existing-summary-target
  printf 'keep\n' > "$DIR/01-SUMMARY.md"
  printf 'new\n' > "$DIR/SUMMARY-1.md"
  printf 'keep\n' > "$DIR/01-CONTEXT.md"
  printf 'new\n' > "$DIR/CONTEXT-1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case existing-summary-target 0 "skipped: SUMMARY-1.md (target 01-SUMMARY.md already exists)"
  expect_output_has existing-summary-target "skipped: CONTEXT-1.md (target 01-CONTEXT.md already exists)"

  fresh_dir unknown-form
  printf 'x\n' > "$DIR/PLAN-1-notes.md"
  printf 'x\n' > "$DIR/SUMMARY-2-draft.md"
  printf 'x\n' > "$DIR/CONTEXT-3-old.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case unknown-form 0 "skipped: PLAN-1-notes.md (unknown compound form)"
  expect_output_has unknown-form "skipped: SUMMARY-2-draft.md (unknown compound form)"
  expect_output_has unknown-form "skipped: CONTEXT-3-old.md (unknown compound form)"
  expect_path unknown-form "$DIR/PLAN-1-notes.md"

  fresh_dir symlink-skipped
  printf 'real\n' > "$TEST_ROOT/real-plan.md"
  ln -s "$TEST_ROOT/real-plan.md" "$DIR/PLAN-1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case_silent symlink-skipped 0
  expect_no_path symlink-skipped "$DIR/01-PLAN.md"

  fresh_dir research-rename
  mkdir -p "$DIR/07-widgets"
  printf 'r\n' > "$DIR/07-widgets/07-01-RESEARCH.md"
  run bash "$NORMALIZE" "$DIR/07-widgets"
  expect_case research-rename 0 "renamed: 07-01-RESEARCH.md -> 07-RESEARCH.md"

  fresh_dir research-ambiguous
  mkdir -p "$DIR/07-widgets"
  printf 'r\n' > "$DIR/07-widgets/07-01-RESEARCH.md"
  printf 'r\n' > "$DIR/07-widgets/07-02-RESEARCH.md"
  run bash "$NORMALIZE" "$DIR/07-widgets"
  expect_case_silent research-ambiguous 0
  expect_path research-ambiguous "$DIR/07-widgets/07-01-RESEARCH.md"

  assert_no_case_failures
}

@test "normalize-plan-filenames arguments: skips quietly unless the path is a placeholder" {
  run bash "$NORMALIZE"
  expect_case_silent no-argument 0

  run bash "$NORMALIZE" "$TEST_ROOT/not-a-dir"
  expect_case_silent missing-dir 0

  run bash "$NORMALIZE" '{phase_dir}'
  expect_case placeholder 0 "skipped, path looks like unexpanded placeholder: {phase_dir}"

  assert_no_case_failures
}

@test "normalize-plan-filenames round dir: promotes only valid, current candidates" {
  fresh_dir uat/remediation/uat/round-01
  write_round_plan "$DIR/plan-1.md" 1
  run bash "$NORMALIZE" "$DIR"
  expect_case valid-candidate 0 "renamed: plan-1.md -> R01-PLAN.md"
  expect_path valid-candidate "$DIR/R01-PLAN.md"
  expect_no_path valid-candidate "$DIR/plan-1.md"

  fresh_dir invalid/remediation/uat/round-01
  printf 'no frontmatter\n' > "$DIR/PLAN-R1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case invalid-candidate 0 "skipped: PLAN-R1.md (candidate is structurally invalid; moved invalid candidate to PLAN-R1.md.invalid)"
  expect_path invalid-candidate "$DIR/PLAN-R1.md.invalid"
  expect_no_path invalid-candidate "$DIR/R01-PLAN.md"

  fresh_dir wrong-round/remediation/uat/round-01
  write_round_plan "$DIR/plan-2.md" 2
  run bash "$NORMALIZE" "$DIR"
  expect_case wrong-round 0 "skipped: plan-2.md (round token does not match round-01)"
  expect_path wrong-round "$DIR/plan-2.md"

  fresh_dir unknown-round-form/remediation/uat/round-01
  write_round_plan "$DIR/plan-1x.md" 1
  run bash "$NORMALIZE" "$DIR"
  expect_case unknown-round-form 0 "skipped: plan-1x.md (unknown remediation round plan form)"

  fresh_dir identical-duplicates/remediation/uat/round-01
  write_round_plan "$DIR/plan-1.md" 1
  cp "$DIR/plan-1.md" "$DIR/PLAN-R1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_status identical-duplicates 0
  expect_output_has identical-duplicates "removed duplicate:"
  expect_path identical-duplicates "$DIR/R01-PLAN.md"

  fresh_dir qa-needs-known-issues/remediation/qa/round-01
  write_round_plan "$DIR/plan-1.md" 1 uat
  run bash "$NORMALIZE" "$DIR"
  expect_case qa-needs-known-issues 0 "candidate is structurally invalid"

  fresh_dir qa-complete/remediation/qa/round-01
  write_round_plan "$DIR/plan-1.md" 1 qa
  run bash "$NORMALIZE" "$DIR"
  expect_case qa-complete 0 "renamed: plan-1.md -> R01-PLAN.md"

  fresh_dir legacy-round/remediation/round-03
  write_round_plan "$DIR/plan-3.md" 3
  run bash "$NORMALIZE" "$DIR"
  expect_case legacy-round 0 "renamed: plan-3.md -> R03-PLAN.md"

  assert_no_case_failures
}

@test "normalize-plan-filenames round dir conflicts: keeps the newest valid plan and fails closed on ties" {
  fresh_dir conflicting-candidates/remediation/uat/round-01
  write_round_plan "$DIR/plan-1.md" 1
  write_round_plan "$DIR/PLAN-R1.md" 01
  printf 'extra\n' >> "$DIR/PLAN-R1.md"
  write_round_plan "$DIR/R01-PLAN.md" 1
  run bash "$NORMALIZE" "$DIR"
  expect_case conflicting-candidates 0 "conflict: multiple non-identical remediation round plan candidates"
  expect_output_has conflicting-candidates "moved existing R01-PLAN.md to R01-PLAN.md.conflict"
  expect_path conflicting-candidates "$DIR/R01-PLAN.md.conflict"
  expect_no_path conflicting-candidates "$DIR/R01-PLAN.md"
  expect_path conflicting-candidates "$DIR/plan-1.md"

  fresh_dir identical-to-target/remediation/uat/round-01
  write_round_plan "$DIR/R01-PLAN.md" 1
  cp "$DIR/R01-PLAN.md" "$DIR/plan-1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case identical-to-target 0 "removed duplicate: plan-1.md (matches R01-PLAN.md)"
  expect_no_path identical-to-target "$DIR/plan-1.md"

  fresh_dir older-candidate/remediation/uat/round-01
  write_round_plan "$DIR/R01-PLAN.md" 1
  write_round_plan "$DIR/plan-1.md" 1
  printf 'older edit\n' >> "$DIR/plan-1.md"
  touch -t 202001010000 "$DIR/plan-1.md"
  touch -t 202101010000 "$DIR/R01-PLAN.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case older-candidate 0 "existing R01-PLAN.md is newer; moved stale candidate to plan-1.md.stale"
  expect_path older-candidate "$DIR/plan-1.md.stale"
  expect_no_file_line older-candidate "$DIR/R01-PLAN.md" 'older edit'

  fresh_dir newer-valid-candidate/remediation/uat/round-01
  write_round_plan "$DIR/R01-PLAN.md" 1
  write_round_plan "$DIR/plan-1.md" 1
  printf 'newer edit\n' >> "$DIR/plan-1.md"
  touch -t 202001010000 "$DIR/R01-PLAN.md"
  touch -t 202101010000 "$DIR/plan-1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case newer-valid-candidate 0 "renamed: plan-1.md -> R01-PLAN.md (replaced existing target)"
  expect_file_line newer-valid-candidate "$DIR/R01-PLAN.md" 'newer edit'

  fresh_dir newer-invalid-candidate/remediation/uat/round-01
  write_round_plan "$DIR/R01-PLAN.md" 1
  printf 'broken\n' > "$DIR/plan-1.md"
  touch -t 202001010000 "$DIR/R01-PLAN.md"
  touch -t 202101010000 "$DIR/plan-1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case newer-invalid-candidate 0 "newer candidate is structurally invalid"
  expect_path newer-invalid-candidate "$DIR/plan-1.md.invalid"
  expect_file_line newer-invalid-candidate "$DIR/R01-PLAN.md" '^title: Fix checkout$'

  fresh_dir same-mtime/remediation/uat/round-01
  write_round_plan "$DIR/R01-PLAN.md" 1
  write_round_plan "$DIR/plan-1.md" 1
  printf 'different\n' >> "$DIR/plan-1.md"
  touch -t 202101010000 "$DIR/R01-PLAN.md" "$DIR/plan-1.md"
  run bash "$NORMALIZE" "$DIR"
  expect_case same-mtime 0 "same mtime but different contents"
  expect_path same-mtime "$DIR/R01-PLAN.md.conflict"
  expect_no_path same-mtime "$DIR/R01-PLAN.md"

  assert_no_case_failures
}

@test "plan-task-count accepts: counts balanced task records within the cap" {
  printf '{"max_tasks_per_plan": 2}\n' > "$CONFIG"
  write_plan '<task type="auto">
  <name>First</name>
</task>
<task type="auto">
  <name>Second</name>
</task>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case at-project-cap 0 "plan_task_count=2"
  expect_output_has at-project-cap "max_tasks_per_plan=2"

  printf '{}\n' > "$CONFIG"
  write_plan '<task type="auto">
  <action>Prose mentioning &lt;task type="auto"&gt; stays inside this record.</action>
</task>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case prose-not-counted 0 "plan_task_count=1"
  expect_output_has prose-not-counted "max_tasks_per_plan=5"

  write_plan '<task>
</task>
  <task id="bare">
  </task>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case attribute-and-indent-forms 0 "plan_task_count=2"

  assert_no_case_failures
}

@test "plan-task-count rejects: fails closed on bad plans, configs and caps" {
  local invalid_cap

  printf '{"max_tasks_per_plan": 1}\n' > "$CONFIG"
  write_plan '<task type="auto">
</task>
<task type="auto">
</task>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case above-project-cap 1 "PLAN has 2 tasks, exceeding max_tasks_per_plan=1"
  expect_output_lacks above-project-cap "plan_task_count="

  printf '{}\n' > "$CONFIG"
  write_plan '<task type="auto">
  <name>Unclosed</name>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case unclosed-task 1 "malformed PLAN task structure"

  write_raw_plan '<tasks>' '<task>' '<task>' '</task>' '</task>' '</tasks>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case nested-task 1 "malformed PLAN task structure"

  write_raw_plan '<tasks>' '<task>' '</task>' '</tasks>' '<tasks>' '<task>' '</task>' '</tasks>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case two-task-blocks 1 "malformed PLAN task structure"

  write_raw_plan '<task>' '</task>'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case task-outside-block 1 "malformed PLAN task structure"

  write_plan 'No task records.'
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case no-task-records 1 "PLAN has no task records"

  write_plan '<task type="auto">
</task>'
  printf '{"max_tasks_per_plan":' > "$CONFIG"
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case malformed-config 1 "project config is not valid JSON"

  rm -f "$CONFIG"
  run bash "$SCRIPT" "$PLAN" "$CONFIG"
  expect_case missing-config 1 "project config is not readable"

  printf '{}\n' > "$CONFIG"
  run bash "$SCRIPT" "$TEST_ROOT/absent.md" "$CONFIG"
  expect_case missing-plan 1 "PLAN is not readable"

  run bash "$SCRIPT" "$PLAN"
  expect_case wrong-arity 1 "usage: plan-task-count.sh"

  for invalid_cap in 0 1.5 '"2"' null; do
    printf '{"max_tasks_per_plan": %s}\n' "$invalid_cap" > "$CONFIG"
    run bash "$SCRIPT" "$PLAN" "$CONFIG"
    expect_case "invalid-cap-$invalid_cap" 1 "max_tasks_per_plan must be a positive integer"
  done

  assert_no_case_failures
}
