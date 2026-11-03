#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  create_test_config
  GUARD="$SCRIPTS_DIR/workflow-spawn-guard.sh"
  cd "$TEST_TEMP_DIR"
  reset_case_failures
}

expect_workflow_state() {
  local label="$1" want="$2"
  [ "$(workflow_state)" = "$want" ] \
    || record_case_failure "$label" "manifest state became $(workflow_state) want=$want"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

generate_workflow() {
  local suffix="$1" project control_root contract task_id agen_out name wgen_out
  project="$TEST_TEMP_DIR/project-$suffix"
  mkdir -p "$project/.lbwc-planning"
  control_root="$project/.temporary-agent-runfiles/runs/wf-$suffix"
  mkdir -p "$control_root"
  jq -n '{workflow_execution:{enabled:true}}' > "$control_root/config.json"
  jq -n '{workflow:{available:true, unavailable_reasons:[]}}' > "$control_root/claude-capabilities.json"
  contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$project" "$suffix" \
    --command integration-test --role scout --team solo --job "guard fixture job $suffix" \
    --group fixed \
    --control-root "$control_root" --requested-backend workflow --resolved-backend workflow \
    --write-capability directory:notes) || return 1
  task_id=$(basename "$contract" .json)
  agen_out=$(LBWC_AGENT_RANDOM_SEED=$RANDOM bash "$SCRIPTS_DIR/agent-generator.sh" scout \
    --job "guard fixture job $suffix" --contract "$contract" --task-id "$task_id" \
    --control-root "$control_root" --write-capability directory:notes \
    --execution-backend workflow 2>&1) || { printf '%s\n' "$agen_out" >&2; return 1; }
  name=$(grep '^SPAWN_READY' <<< "$agen_out" | awk '{print $2}')
  [ -n "$name" ] || return 1
  wgen_out=$(bash "$SCRIPTS_DIR/workflow-generator.sh" solo scout \
    --job "guard fixture job $suffix" --contract "$contract" --task-id "$task_id" \
    --control-root "$control_root" --name "$name" 2>&1) || { printf '%s\n' "$wgen_out" >&2; return 1; }
  printf '%s\n%s\n' "$control_root" "$control_root/workflows/$task_id.js"
}

build_fixture() {
  local fixture
  fixture=$(generate_workflow "$1")
  CONTROL_ROOT=$(sed -n 1p <<< "$fixture")
  SCRIPT_PATH=$(sed -n 2p <<< "$fixture")
  WORKFLOW_ID=$(basename "$SCRIPT_PATH" .js)
}

workflow_call_json() {
  jq -cn --arg sp "$1" --argjson args "${2:-null}" \
    '{tool_name:"Workflow",tool_input:{scriptPath:$sp,args:$args}}'
}

workflow_state() {
  jq -r --arg id "$WORKFLOW_ID" '.workflows[$id].state' "$CONTROL_ROOT/workflow-manifest.json"
}

run_guard_in_root() {
  run bash -c 'printf "%s" "$1" | LBWC_CONTROL_ROOT="$2" bash "$3"' _ "$1" "$CONTROL_ROOT" "$GUARD"
}

run_guard_plain() {
  run bash -c 'printf "%s" "$1" | bash "$2"' _ "$1" "${2:-$GUARD}"
}

apply_mutation() {
  case "$1" in
    append-to-script) printf '\n// tampered after generation\n' >> "$SCRIPT_PATH" ;;
    isolation-on)
      jq '.worktree_isolation="on"' "$CONTROL_ROOT/config.json" > "$CONTROL_ROOT/config.tmp"
      mv "$CONTROL_ROOT/config.tmp" "$CONTROL_ROOT/config.json"
      ;;
    rewrite-recorded-path)
      jq --arg id "$WORKFLOW_ID" '.workflows[$id].script_path = "/elsewhere/other.js"' \
        "$CONTROL_ROOT/workflow-manifest.json" > "$CONTROL_ROOT/manifest.rewrite"
      mv "$CONTROL_ROOT/manifest.rewrite" "$CONTROL_ROOT/workflow-manifest.json"
      ;;
  esac
}

write_library_stub() {
  case "$1" in
    loads) printf ':\n' > "$2" ;;
    fails) printf 'return 1\n' > "$2" ;;
  esac
}

run_library_table() {
  local label manifest_stub root_stub message shadow
  while IFS='|' read -r label manifest_stub root_stub message; do
    [ -n "$label" ] || continue
    shadow="$TEST_TEMP_DIR/shadow-$label"
    mkdir -p "$shadow/lib"
    cp "$GUARD" "$shadow/workflow-spawn-guard.sh"
    write_library_stub "$manifest_stub" "$shadow/lib/workflow-manifest.sh"
    write_library_stub "$root_stub" "$shadow/lib/lbwc-control-root.sh"
    run_guard_plain '{"tool_name":"Workflow","tool_input":{"scriptPath":"/tmp/whatever.js"}}' \
      "$shadow/workflow-spawn-guard.sh" </dev/null
    expect_case "$label" 2 "$message"
  done
}

run_input_table() {
  local label json message
  while IFS='|' read -r label json message; do
    [ -n "$label" ] || continue
    run_guard_plain "${json//@TMP@/$TEST_TEMP_DIR}" </dev/null
    expect_case "$label" 2 "$message"
  done
}

run_location_table() {
  local label destination message
  while IFS='|' read -r label destination message; do
    [ -n "$label" ] || continue
    build_fixture "loc-$label"
    destination=${destination//@WF@/$(dirname "$SCRIPT_PATH")}
    destination=${destination//@RUNS@/$(dirname "$CONTROL_ROOT")}
    cp "$SCRIPT_PATH" "$destination"
    run_guard_in_root "$(workflow_call_json "$destination")" </dev/null
    expect_case "$label" 2 "$message"
    [ "$(workflow_state)" = registered ] \
      || record_case_failure "$label" "manifest state became $(workflow_state)"
  done
}

run_recorded_fact_table() {
  local label mutation args message
  while IFS='|' read -r label mutation args message; do
    [ -n "$label" ] || continue
    build_fixture "fact-$label"
    apply_mutation "$mutation"
    run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH" "$args")" </dev/null
    expect_case "$label" 2 "$message"
    [ "$(workflow_state)" = registered ] \
      || record_case_failure "$label" "manifest state became $(workflow_state)"
  done
}

@test "workflow spawn guard passes non-Workflow input and fails closed on missing tools, libraries, or malformed calls" {
  local no_jq_path="$TEST_TEMP_DIR/no-jq-bin"
  mkdir -p "$no_jq_path"
  ln -s "$(command -v bash)" "$no_jq_path/bash"

  run env PATH="$no_jq_path" bash -c "printf '%s' '{}' | bash '$GUARD'"
  expect_case missing-jq 2 "jq not available"

  run_guard_plain 'not json at all'
  expect_case malformed-json 2 "could not parse tool call input"

  run_guard_plain '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  expect_case_silent non-workflow-passes 0

  run_guard_plain ''
  expect_case_silent empty-input-passes 0

  run_library_table <<'CASES'
manifest-library-absent|absent|absent|workflow manifest library is unavailable
manifest-library-fails-to-load|fails|absent|workflow manifest library failed to load
control-root-library-absent|loads|absent|control root library is unavailable
control-root-library-fails-to-load|loads|fails|control root library failed to load
CASES

  run_input_table <<'CASES'
missing-scriptPath|{"tool_name":"Workflow","tool_input":{}}|Workflow call has no scriptPath
relative-scriptPath|{"tool_name":"Workflow","tool_input":{"scriptPath":"workflows/foo.js"}}|scriptPath must be an absolute path
absolute-scriptPath-missing-on-disk|{"tool_name":"Workflow","tool_input":{"scriptPath":"@TMP@/does-not-exist.js"}}|scriptPath does not resolve to a file on disk
CASES

  assert_no_case_failures
}

@test "workflow spawn guard blocks a call that no longer matches its registered workflow and leaves it registered" {
  build_fixture inline
  run_guard_in_root "$(jq -cn --arg sp "$SCRIPT_PATH" '{tool_name:"Workflow",tool_input:{scriptPath:$sp,script:"await log(1)"}}')"
  expect_case inline-script 2 "carries an inline 'script' parameter"
  expect_workflow_state inline-script registered

  run_location_table <<'CASES'
outside-registered-directory|@RUNS@/decoy.js|outside the registered generated directory
not-a-js-file|@WF@/notjs.txt|does not name a generated workflow script
unsafe-contract-id|@WF@/a..b.js|names an unsafe workflow identity
no-manifest-entry|@WF@/evil.js|has no manifest entry
CASES

  run_recorded_fact_table <<'CASES'
isolation-unavailable|isolation-on|null|worktree_isolation=on cannot run the workflow backend
recorded-path-differs|rewrite-recorded-path|null|does not match the path recorded at generation
file-digest-differs|append-to-script|null|file digest no longer matches the digest recorded at generation
args-differ|none|{"foo":"bar"}|args do not match the args recorded at generation
CASES

  build_fixture badmanifest
  printf 'not json at all' > "$CONTROL_ROOT/workflow-manifest.json"
  run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH")"
  expect_case malformed-manifest 2 "workflow manifest is unreadable or malformed"

  build_fixture noroot
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning"
  run env -u LBWC_CONTROL_ROOT -u LBWC_PLANNING_DIR bash -c 'printf "%s" "$1" | bash "$2"' \
    _ "$(workflow_call_json "$SCRIPT_PATH")" "$GUARD"
  expect_case unresolvable-control-root 2 "has no resolvable control root or manifest"

  assert_no_case_failures
}

@test "workflow spawn guard claims a valid matching scriptPath once and blocks a second start" {
  build_fixture valid
  jq '.worktree_isolation="off"' "$CONTROL_ROOT/config.json" > "$CONTROL_ROOT/config.tmp"
  mv "$CONTROL_ROOT/config.tmp" "$CONTROL_ROOT/config.json"

  run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH")"
  expect_case_silent valid-call-allowed 0
  expect_workflow_state valid-call-allowed running

  run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH")"
  expect_case already-running 2 "already running and cannot be started again"
  expect_workflow_state already-running running

  assert_no_case_failures
}

@test "registered Workflow hook rejects a relative script path" {
  local command
  command=$(jq -r '.hooks.PreToolUse[] | select(.matcher | split("|") | index("Workflow")) | .hooks[].command' "$PROJECT_ROOT/hooks/hooks.json")
  run env CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" bash -c "$command" <<< '{"hook_event_name":"PreToolUse","tool_name":"Workflow","tool_input":{"scriptPath":"workflows/unknown.js"}}'
  [ "$status" -eq 2 ]
}
