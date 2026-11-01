load test_helper
load gate_case_helper
load gate_case_files

setup_script_contract_workspace() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR" || return 1
  git init -q
  reset_case_failures
  export LBWC_PLANNING_DIR="$TEST_TEMP_DIR/.lbwc-planning"
  printf -v PLANNING '%s' "$LBWC_PLANNING_DIR"
  printf -v PHASE '%s' "$PLANNING/phases/${1:-03-checkout}"
  mkdir -p "$PHASE"
}

setup() {
  setup_script_contract_workspace
}

teardown() {
  await_git_ai
  cd "$BATS_TEST_DIRNAME" || return 1
  teardown_temp_dir
}
