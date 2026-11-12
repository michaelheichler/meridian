#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  ROOT=$(cd -P "$(mktemp -d)" && pwd -P)
  mkdir -p "$ROOT/.meridian" "$ROOT/.temporary-agent-runfiles/runs/team-one"
  printf '%s\n' '{}' > "$ROOT/.meridian/config.json"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/lib/meridian-control-root.sh"
  RUN="$ROOT/.temporary-agent-runfiles/runs/team-one"
  reset_case_failures
}

teardown() {
  rm -rf "$ROOT"
}

run_resolve() {
  local control=$1 project=$2 start=$3
  shift 3
  run env -u MERIDIAN_CONTROL_ROOT -u MERIDIAN_PLANNING_DIR "$@" \
    bash -c '. "$1"; meridian_resolve_control_root "$2" "$3" "$4"' _ "$SCRIPT" "$control" "$project" "$start" < /dev/null
}

run_validate() {
  run bash -c '. "$1"; meridian_control_root_validate "$2" "${3:-0}"' _ "$SCRIPT" "$@" < /dev/null
}

expect_output_is() {
  [ "$output" = "$2" ] || record_case_failure "$1" "output=[$output] want=[$2]"
}

@test "meridian_resolve_control_root: selects the planning root or the single temporary run from each source" {
  run_resolve "" "" "$ROOT"
  expect_case start-dir 0 ""
  expect_output_is start-dir "$ROOT/.meridian"

  mkdir -p "$ROOT/deep/er"
  run_resolve "" "" "$ROOT/deep/er"
  expect_case start-nested-dir-walks-up 0 ""
  expect_output_is start-nested-dir-walks-up "$ROOT/.meridian"

  run_resolve "$RUN" "" "$ROOT"
  expect_case explicit-run 0 ""
  expect_output_is explicit-run "$RUN"

  run_resolve "" "$ROOT" "/"
  expect_case requested-project 0 ""
  expect_output_is requested-project "$ROOT/.meridian"

  run_resolve "" "" "/" MERIDIAN_CONTROL_ROOT="$RUN"
  expect_case control-root-env 0 ""
  expect_output_is control-root-env "$RUN"

  run_resolve "" "" "/" MERIDIAN_PLANNING_DIR="$ROOT/.meridian"
  expect_case planning-dir-env 0 ""
  expect_output_is planning-dir-env "$ROOT/.meridian"

  rm "$ROOT/.meridian/config.json"
  printf '%s\n' '{}' > "$ROOT/.meridian/.agent-manifest.json"
  run_resolve "" "" "/" MERIDIAN_PLANNING_DIR="$ROOT/.meridian"
  expect_case planning-dir-env-manifest-only 0 ""
  expect_output_is planning-dir-env-manifest-only "$ROOT/.meridian"

  rm -rf "$ROOT/.meridian"
  run_resolve "" "" "$ROOT"
  expect_case single-temporary-run 0 ""
  expect_output_is single-temporary-run "$RUN"

  assert_no_case_failures
}

@test "meridian_resolve_control_root and meridian_control_root_validate: reject anything that is not one valid control root" {
  mkdir -p "$ROOT/not-control" "$ROOT/.temporary-agent-runfiles/runs/team-one/nested" "$ROOT/.temporary-agent-runfiles/runs/.hidden"
  run_validate "$ROOT/not-control"
  expect_status arbitrary-directory 1
  run_validate "$RUN/nested"
  expect_status run-nested-below-a-run 1
  mkdir -p "$ROOT/.temporary-agent-runfiles/other/job"
  run_validate "$ROOT/.temporary-agent-runfiles/other/job"
  expect_status run-outside-runs-directory 1
  run_validate "$ROOT/.temporary-agent-runfiles/runs/.hidden"
  expect_status run-id-starts-with-dot 1
  run_validate "$ROOT/missing"
  expect_status missing-directory 1
  run_validate ""
  expect_status empty-candidate 1

  ln -s "$ROOT/.meridian" "$ROOT/linked"
  run_validate "$ROOT/linked"
  expect_status symlinked-candidate 1

  printf '%s\n' '[]' > "$ROOT/.meridian/config.json"
  run_validate "$ROOT/.meridian"
  expect_status planning-config-not-an-object 1

  rm "$ROOT/.meridian/config.json"
  printf '%s\n' '{}' > "$ROOT/.meridian/.agent-manifest.json"
  run_validate "$ROOT/.meridian"
  expect_status manifest-only-planning-not-allowed 1

  run_resolve "$ROOT/not-control" "" "$ROOT"
  expect_status explicit-control-not-valid 1

  rm -rf "$ROOT/.meridian"
  mkdir -p "$ROOT/.temporary-agent-runfiles/runs/team-two"
  run_resolve "" "" "$ROOT"
  expect_status ambiguous-temporary-runs 1

  local bare
  bare=$(cd -P "$(mktemp -d)" && pwd -P)
  run_resolve "" "" "$bare"
  expect_status no-control-root-anywhere 1
  rm -rf "$bare"

  assert_no_case_failures
}

@test "meridian_control_root_* path accessors: derive project, manifest, lock, contracts and agents paths for both root kinds" {
  local row label root fn want
  for row in \
    "planning-project-root|$ROOT/.meridian|meridian_control_root_project_root|$ROOT" \
    "planning-manifest|$ROOT/.meridian|meridian_control_root_manifest_path|$ROOT/.meridian/.agent-manifest.json" \
    "planning-lock|$ROOT/.meridian|meridian_control_root_lock_path|$ROOT/.meridian/.agent-manifest.lock" \
    "planning-workflow-manifest|$ROOT/.meridian|meridian_control_root_workflow_manifest_path|$ROOT/.meridian/.workflow-manifest.json" \
    "planning-workflow-lock|$ROOT/.meridian|meridian_control_root_workflow_manifest_lock_path|$ROOT/.meridian/.workflow-manifest.lock" \
    "planning-workflows-dir|$ROOT/.meridian|meridian_control_root_workflows_dir|$ROOT/.meridian/workflows" \
    "planning-contracts-dir|$ROOT/.meridian|meridian_control_root_contracts_dir|$ROOT/.meridian/.contracts/tasks" \
    "planning-agents-dir|$ROOT/.meridian|meridian_control_root_generated_agents_dir|$ROOT/.claude/agents" \
    "run-project-root|$RUN|meridian_control_root_project_root|$ROOT" \
    "run-manifest|$RUN|meridian_control_root_manifest_path|$RUN/agent-manifest.json" \
    "run-lock|$RUN|meridian_control_root_lock_path|$RUN/agent-manifest.lock" \
    "run-workflow-manifest|$RUN|meridian_control_root_workflow_manifest_path|$RUN/workflow-manifest.json" \
    "run-workflow-lock|$RUN|meridian_control_root_workflow_manifest_lock_path|$RUN/workflow-manifest.lock" \
    "run-workflows-dir|$RUN|meridian_control_root_workflows_dir|$RUN/workflows" \
    "run-contracts-dir|$RUN|meridian_control_root_contracts_dir|$RUN/contracts/tasks" \
    "run-agents-dir|$RUN|meridian_control_root_generated_agents_dir|$ROOT/.claude/agents"; do
    IFS='|' read -r label root fn want <<< "$row"
    run bash -c '. "$1"; "$2" "$3"' _ "$SCRIPT" "$fn" "$root" < /dev/null
    expect_case "$label" 0 ""
    expect_output_is "$label" "$want"
  done

  run bash -c '. "$1"; meridian_control_root_manifest_path "$2"' _ "$SCRIPT" "$ROOT/missing" < /dev/null
  expect_status accessor-on-missing-root 1

  assert_no_case_failures
}
