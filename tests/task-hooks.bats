#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ADMISSION="$REPO_ROOT/scripts/task-admission-guard.sh"
  COMPLETION="$REPO_ROOT/scripts/task-completion-guard.sh"
  FIXTURE_BASE="$(mktemp -d)"
  FIXTURE_BASE="$(cd "$FIXTURE_BASE" && pwd -P)"
}

teardown() {
  rm -rf "$FIXTURE_BASE"
}

fixture_root() {
  TEST_ROOT="$FIXTURE_BASE/$1"
  CONTROL_ROOT="$TEST_ROOT/.temporary-agent-runfiles/runs/native-task"
  mkdir -p "$CONTROL_ROOT"
  CONTRACT=$(bash "$REPO_ROOT/scripts/task-contract.sh" issue "$TEST_ROOT" native-task \
    --command team --role web-engineer --team solo --job "implement native task" \
    --control-root "$CONTROL_ROOT" --write-capability directory:src/web)
  CONTRACT_ID="$(basename "$CONTRACT" .json)"
  jq -n --arg contract "$CONTRACT" --arg id "$CONTRACT_ID" --arg root "$TEST_ROOT" \
    '{agents:{"lbwc-web-engineer-native":{
      name:"lbwc-web-engineer-native", role:"web-engineer", state:"running",
      project_root:$root, contract_enabled:true, contract_path:$contract,
      contract_id:$id, contract_digest:(input_filename | ""), task_identity:$id,
      schema_version:3, capabilities:[{access:"write",kind:"directory",path:"src/web"}],
      write_allowances:["src/web"], runtime_kind:"native-team", communication_policy:"native-team"
    }}}' /dev/null > "$CONTROL_ROOT/agent-manifest.json"
  CONTRACT_DIGEST=$(jq -r '.contract_digest' "$CONTRACT")
  jq --arg digest "$CONTRACT_DIGEST" '.agents["lbwc-web-engineer-native"].contract_digest = $digest' \
    "$CONTROL_ROOT/agent-manifest.json" > "$CONTROL_ROOT/manifest.tmp"
  mv "$CONTROL_ROOT/manifest.tmp" "$CONTROL_ROOT/agent-manifest.json"
}

advance_contract() {
  local state
  for state in "$@"; do
    bash "$REPO_ROOT/scripts/task-contract.sh" state "$TEST_ROOT" "$CONTRACT_ID" "$state" >/dev/null
  done
}

task_event() {
  local event="$1" task_id="$2" subject="$3"
  jq -cn --arg event "$event" --arg cwd "$TEST_ROOT" --arg id "$task_id" --arg subject "$subject" \
    '{hook_event_name:$event,cwd:$cwd,task_id:$id,task_subject:$subject,task_description:"implement native task",team_name:"native-team"}'
}

fire_hook() {
  local script="$1" event="$2" task_id="$3" subject="${4:-}"
  task_event "$event" "$task_id" "$subject" | LBWC_CONTROL_ROOT="$CONTROL_ROOT" bash "$script" 2>&1
}

expect_manifest() {
  local label="$1" filter="$2"
  jq -e "$filter" "$CONTROL_ROOT/agent-manifest.json" >/dev/null \
    || { echo "[$label] manifest does not satisfy $filter: $(cat "$CONTROL_ROOT/agent-manifest.json")"; return 1; }
}

expect_run_status() {
  local label="$1" want="$2" fragment="${3:-}"
  [ "$status" -eq "$want" ] || { echo "[$label] exit $status want $want, output: $output"; return 1; }
  [[ "$output" == *"$fragment"* ]] || { echo "[$label] missing [$fragment], output: $output"; return 1; }
}

expect_denied() {
  local label="$1" script="$2" event="$3" task_id="$4" subject="$5" reason="$6" before after code
  before=$(cat "$CONTROL_ROOT/agent-manifest.json")
  output=$(fire_hook "$script" "$event" "$task_id" "$subject") && code=0 || code=$?
  after=$(cat "$CONTROL_ROOT/agent-manifest.json")
  [ "$code" -eq 2 ] || { echo "[$label] exit $code, output: $output"; return 1; }
  [[ "$output" == *"$reason"* ]] || { echo "[$label] reason missing, output: $output"; return 1; }
  [ "$before" = "$after" ] || { echo "[$label] manifest changed on deny"; return 1; }
}

hook_raw() {
  local script="$1" payload="$2" root="${3:-}"
  printf '%s' "$payload" | env -u LBWC_CONTROL_ROOT -u LBWC_PLANNING_DIR ${root:+LBWC_CONTROL_ROOT="$root"} bash "$script" 2>&1
}

hook_closed_stdin() {
  LBWC_CONTROL_ROOT="$CONTROL_ROOT" bash "$1" < "$TEST_ROOT" 2>&1
}

hook_without_jq() {
  mkdir -p "$TEST_ROOT/empty-bin"
  PATH="$TEST_ROOT/empty-bin" "$BASH" "$1" </dev/null 2>&1
}

expect_blocked() {
  local label="$1" reason="$2" before after code
  shift 2
  before=$(cat "$CONTROL_ROOT/agent-manifest.json")
  output=$("$@") && code=0 || code=$?
  after=$(cat "$CONTROL_ROOT/agent-manifest.json")
  [ "$code" -eq 2 ] || { echo "[$label] exit $code, output: $output"; return 1; }
  [[ "$output" == *"$reason"* ]] || { echo "[$label] reason missing, output: $output"; return 1; }
  [ "$before" = "$after" ] || { echo "[$label] manifest changed on deny"; return 1; }
}

expect_ignored() {
  local label="$1" script="$2" payload="$3" before
  before=$(cat "$CONTROL_ROOT/agent-manifest.json")
  run hook_raw "$script" "$payload" "$CONTROL_ROOT"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "[$label] exit $status output: $output"; return 1; }
  [ "$before" = "$(cat "$CONTROL_ROOT/agent-manifest.json")" ] || { echo "[$label] manifest changed"; return 1; }
}

@test "TaskCreated binds a native task to one pending or dispatched schema 3 contract and denies every other invocation without touching the manifest" {
  fixture_root bind-pending
  run bash -c 'jq -cn --arg cwd "$1" --arg id native-1 --arg subject "$2" '\''{hook_event_name:"TaskCreated",cwd:$cwd,task_id:$id,task_subject:$subject,task_description:"implement native task"}'\'' | LBWC_CONTROL_ROOT="$3" bash "$4"' _ "$TEST_ROOT" "$CONTRACT_ID" "$CONTROL_ROOT" "$ADMISSION"
  expect_run_status bind-pending 0
  expect_manifest bind-pending "$(printf '.tasks["native-1"].contract_id == "%s" and .tasks["native-1"].state == "created"' "$CONTRACT_ID")"

  fixture_root bind-dispatched
  advance_contract dispatched
  run fire_hook "$ADMISSION" TaskCreated native-8 "$CONTRACT_ID"
  expect_run_status bind-dispatched 0
  expect_manifest bind-dispatched '.tasks | keys == ["native-8"]'

  fixture_root uncontracted
  run bash -c 'jq -cn --arg cwd "$1" '\''{hook_event_name:"TaskCreated",cwd:$cwd,task_id:"native-2",task_subject:"unrelated-task"}'\'' | LBWC_CONTROL_ROOT="$2" bash "$3"' _ "$TEST_ROOT" "$CONTROL_ROOT" "$ADMISSION"
  expect_run_status uncontracted 2 "no pending native-team contract"
  expect_manifest uncontracted '(.tasks // {}) | has("native-2") | not'

  fixture_root unusable-contract
  fire_hook "$ADMISSION" TaskCreated native-5 "$CONTRACT_ID" >/dev/null
  expect_denied "task id already bound" "$ADMISSION" TaskCreated native-5 "$CONTRACT_ID" "is already bound"
  cp "$CONTRACT" "$TEST_ROOT/contract.orig"
  jq '.role = "tampered-role"' "$TEST_ROOT/contract.orig" > "$CONTRACT"
  expect_denied "tampered contract in planned state" "$ADMISSION" TaskCreated native-11 "$CONTRACT_ID" "missing, stale, or invalid"
  cp "$TEST_ROOT/contract.orig" "$CONTRACT"
  advance_contract dispatched running
  expect_denied "contract past dispatched" "$ADMISSION" TaskCreated native-6 "$CONTRACT_ID" "missing, stale, or invalid"
  rm "$CONTRACT"
  expect_denied "contract file missing" "$ADMISSION" TaskCreated native-7 "$CONTRACT_ID" "missing, stale, or invalid"

  fixture_root malformed-created
  expect_blocked "jq missing" "jq not available" hook_without_jq "$ADMISSION"
  expect_blocked "payload unreadable" "unable to read TaskCreated payload" hook_closed_stdin "$ADMISSION"
  expect_blocked "no control root" "no resolvable LBWC control root" hook_raw "$ADMISSION" \
    '{"hook_event_name":"TaskCreated","cwd":"'"$BATS_TEST_TMPDIR"'","task_id":"t","task_subject":"s"}'
  expect_blocked "task id missing" "missing task identity" hook_raw "$ADMISSION" \
    '{"hook_event_name":"TaskCreated","cwd":"'"$TEST_ROOT"'","task_subject":"s"}' "$CONTROL_ROOT"
  expect_blocked "task subject missing" "missing task identity" hook_raw "$ADMISSION" \
    '{"hook_event_name":"TaskCreated","cwd":"'"$TEST_ROOT"'","task_id":"t"}' "$CONTROL_ROOT"
  expect_ignored "admission ignores TaskCompleted" "$ADMISSION" '{"hook_event_name":"TaskCompleted","task_id":"t","task_subject":"s"}'
}

@test "TaskCompleted records completion only for a verified bound contract and denies every other invocation without touching the manifest" {
  fixture_root unverified
  fire_hook "$ADMISSION" TaskCreated native-3 "$CONTRACT_ID" >/dev/null
  run bash -c 'jq -cn --arg cwd "$1" '\''{hook_event_name:"TaskCompleted",cwd:$cwd,task_id:"native-3"}'\'' | LBWC_CONTROL_ROOT="$2" bash "$3"' _ "$TEST_ROOT" "$CONTROL_ROOT" "$COMPLETION"
  expect_run_status unverified 2 "contract is not verified"
  expect_manifest unverified '.tasks["native-3"].state == "created"'

  fixture_root verified
  fire_hook "$ADMISSION" TaskCreated native-4 "$CONTRACT_ID" >/dev/null
  advance_contract dispatched running awaiting_review verified
  run bash -c 'jq -cn --arg cwd "$1" '\''{hook_event_name:"TaskCompleted",cwd:$cwd,task_id:"native-4"}'\'' | LBWC_CONTROL_ROOT="$2" bash "$3"' _ "$TEST_ROOT" "$CONTROL_ROOT" "$COMPLETION"
  expect_run_status verified 0
  expect_manifest verified '.tasks["native-4"].state == "completed"'

  fixture_root unusable-binding
  expect_denied "task never bound" "$COMPLETION" TaskCompleted native-9 "" "has no LBWC contract binding"
  fire_hook "$ADMISSION" TaskCreated native-10 "$CONTRACT_ID" >/dev/null
  jq '.tasks["native-10"].state = "completed"' "$CONTROL_ROOT/agent-manifest.json" > "$CONTROL_ROOT/m.tmp"
  mv "$CONTROL_ROOT/m.tmp" "$CONTROL_ROOT/agent-manifest.json"
  expect_denied "binding already completed" "$COMPLETION" TaskCompleted native-10 "" "binding is invalid"
  jq '.tasks["native-10"].state = "created"' "$CONTROL_ROOT/agent-manifest.json" > "$CONTROL_ROOT/m.tmp"
  mv "$CONTROL_ROOT/m.tmp" "$CONTROL_ROOT/agent-manifest.json"
  rm "$CONTRACT"
  expect_denied "bound contract file missing" "$COMPLETION" TaskCompleted native-10 "" "binding is invalid"

  fixture_root malformed-completed
  expect_blocked "jq missing" "jq not available" hook_without_jq "$COMPLETION"
  expect_blocked "payload unreadable" "unable to read TaskCompleted payload" hook_closed_stdin "$COMPLETION"
  expect_blocked "no control root" "no resolvable LBWC control root" hook_raw "$COMPLETION" \
    '{"hook_event_name":"TaskCompleted","cwd":"'"$BATS_TEST_TMPDIR"'","task_id":"t"}'
  expect_blocked "task id missing" "missing task identity" hook_raw "$COMPLETION" \
    '{"hook_event_name":"TaskCompleted","cwd":"'"$TEST_ROOT"'"}' "$CONTROL_ROOT"
  expect_ignored "completion ignores TaskCreated" "$COMPLETION" '{"hook_event_name":"TaskCreated","task_id":"t"}'
}

@test "hooks register native task admission and completion without native config edits" {
  fixture_root registration
  run jq -e '
    (.hooks.TaskCreated[0].hooks[0].command | contains("task-admission-guard.sh"))
    and (.hooks.TaskCompleted[0].hooks[0].command | contains("task-completion-guard.sh"))
  ' "$REPO_ROOT/hooks/hooks.json"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_ROOT/.claude/teams" ]
}
