#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  create_test_config
  GUARD="$SCRIPTS_DIR/workflow-spawn-guard.sh"
  cd "$TEST_TEMP_DIR"
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
  reset_case_failures
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
  reset_case_failures
  while IFS='|' read -r label json message; do
    [ -n "$label" ] || continue
    run_guard_plain "${json//@TMP@/$TEST_TEMP_DIR}" </dev/null
    expect_case "$label" 2 "$message"
  done
}

run_location_table() {
  local label destination message
  reset_case_failures
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
  reset_case_failures
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

@test "missing jq blocks workflow spawns before input handling" {
  local no_jq_path="$TEST_TEMP_DIR/no-jq-bin"
  mkdir -p "$no_jq_path"
  ln -s "$(command -v bash)" "$no_jq_path/bash"

  run env PATH="$no_jq_path" bash -c "printf '%s' '{}' | bash '$GUARD'"

  [ "$status" -eq 2 ]
  [[ "$output" == *"jq not available"* ]]
}

@test "malformed JSON input is blocked instead of skipping the guard" {
  run_guard_plain 'not json at all'

  [ "$status" -eq 2 ]
  [[ "$output" == *"could not parse tool call input"* ]]
}

@test "non-Workflow tool calls pass through untouched" {
  run_guard_plain '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty tool call input passes through untouched" {
  run_guard_plain ''

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "workflow spawn guard fails closed when a required library cannot load" {
  run_library_table <<'CASES'
manifest-library-absent|absent|absent|workflow manifest library is unavailable
manifest-library-fails-to-load|fails|absent|workflow manifest library failed to load
control-root-library-absent|loads|absent|control root library is unavailable
control-root-library-fails-to-load|loads|fails|control root library failed to load
CASES

  assert_no_case_failures
}

@test "workflow spawn guard blocks a malformed Workflow call before touching the filesystem" {
  run_input_table <<'CASES'
missing-scriptPath|{"tool_name":"Workflow","tool_input":{}}|Workflow call has no scriptPath
relative-scriptPath|{"tool_name":"Workflow","tool_input":{"scriptPath":"workflows/foo.js"}}|scriptPath must be an absolute path
absolute-scriptPath-missing-on-disk|{"tool_name":"Workflow","tool_input":{"scriptPath":"@TMP@/does-not-exist.js"}}|scriptPath does not resolve to a file on disk
CASES

  assert_no_case_failures
}

@test "workflow spawn guard blocks an inline script parameter and leaves the workflow registered" {
  build_fixture inline

  run_guard_in_root "$(jq -cn --arg sp "$SCRIPT_PATH" '{tool_name:"Workflow",tool_input:{scriptPath:$sp,script:"await log(1)"}}')"

  [ "$status" -eq 2 ]
  [[ "$output" == *"carries an inline 'script' parameter"* ]]
  [ "$(workflow_state)" = "registered" ]
}

@test "workflow spawn guard blocks a scriptPath that is not a registered generated script" {
  run_location_table <<'CASES'
outside-registered-directory|@RUNS@/decoy.js|outside the registered generated directory
not-a-js-file|@WF@/notjs.txt|does not name a generated workflow script
unsafe-contract-id|@WF@/a..b.js|names an unsafe workflow identity
no-manifest-entry|@WF@/evil.js|has no manifest entry
CASES

  assert_no_case_failures
}

@test "workflow spawn guard blocks a script whose recorded path, digest, or args no longer match" {
  run_recorded_fact_table <<'CASES'
recorded-path-differs|rewrite-recorded-path|null|does not match the path recorded at generation
file-digest-differs|append-to-script|null|file digest no longer matches the digest recorded at generation
args-differ|none|{"foo":"bar"}|args do not match the args recorded at generation
CASES

  assert_no_case_failures
}

@test "workflow spawn guard fails closed on a malformed workflow manifest" {
  build_fixture badmanifest
  printf 'not json at all' > "$CONTROL_ROOT/workflow-manifest.json"

  run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH")"

  [ "$status" -eq 2 ]
  [[ "$output" == *"workflow manifest is unreadable or malformed"* ]]
}

@test "workflow spawn guard fails closed when the control root cannot be resolved" {
  build_fixture noroot
  rm -rf "$TEST_TEMP_DIR/.lbwc-planning"

  run env -u LBWC_CONTROL_ROOT -u LBWC_PLANNING_DIR bash -c 'printf "%s" "$1" | bash "$2"' \
    _ "$(workflow_call_json "$SCRIPT_PATH")" "$GUARD"

  [ "$status" -eq 2 ]
  [[ "$output" == *"has no resolvable control root or manifest"* ]]
}

@test "workflow spawn guard allows a valid scriptPath with matching args and digest and claims it" {
  build_fixture valid

  run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH")"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(workflow_state)" = "running" ]
}

@test "workflow spawn guard blocks a workflow that is already running" {
  build_fixture rerun
  run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH")"
  [ "$status" -eq 0 ]

  run_guard_in_root "$(workflow_call_json "$SCRIPT_PATH")"

  [ "$status" -eq 2 ]
  [[ "$output" == *"already running and cannot be started again"* ]]
  [ "$(workflow_state)" = "running" ]
}

@test "workflow spawn guard is registered with hooks.json" {
  run jq -e '
    .hooks.PreToolUse[]
    | select(.matcher == "Workflow")
    | .hooks[]
    | select(.command | contains("workflow-spawn-guard.sh"))
  ' "$PROJECT_ROOT/hooks/hooks.json"

  [ "$status" -eq 0 ]
}
