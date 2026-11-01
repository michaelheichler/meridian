#!/usr/bin/env bats

setup() {
  ROOT="$(mktemp -d)"
  ROOT_CANON="$(cd "$ROOT" && pwd -P)"
  PLAN="$ROOT/PLAN.md"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/task-contract.sh"
  PLAN_CONTRACT="$ROOT/.lbwc-planning/.contracts/tasks/09-PLAN-write-contract.json"
  PLAN_ID="09-PLAN-write-contract"
  cat >"$PLAN" <<'PLAN'
---
phase: 9
---
<tasks>
<task type="auto">
<name>write contract</name>
<role>coding-dijkstra</role>
<files>src/contract.py
tests/task-contract.bats</files>
<action>Implement the writer.</action>
<verify>Run the contract tests.</verify>
<done>Contract is durable.</done>
<strategy>tdd</strategy>
</task>
</tasks>
PLAN
}

teardown() { rm -rf "$ROOT"; }

make_control_root() {
  CONTROL_ROOT="$ROOT/.temporary-agent-runfiles/runs/$1"
  mkdir -p "$CONTROL_ROOT"
  CONTROL_ROOT="$(cd -P "$CONTROL_ROOT" && pwd -P)"
}

open_plan() {
  bash "$SCRIPT" open "$PLAN" "$ROOT" "write contract" "$@"
}

issue_team() {
  local name="$1"
  shift
  bash "$SCRIPT" issue "$ROOT" "$name" \
    --command team --role web-engineer --team solo --job "Implement the web scope" "$@"
}

written_contracts() {
  find "$ROOT/.lbwc-planning/.contracts/tasks" "$ROOT/.temporary-agent-runfiles" -name '*.json' -type f 2>/dev/null || true
}

expect_rejected() {
  local label="$1" message="$2"
  shift 2
  run "$@"
  if [ "$status" -eq 0 ] || [[ "$output" != *"$message"* ]]; then
    echo "case=$label status=$status expected_message=$message" >&2
    echo "$output" >&2
    return 1
  fi
}

expect_contract() {
  local label="$1" file="$2" filter="$3"
  shift 3
  if ! jq -e "$@" "$filter" "$file" >/dev/null; then
    echo "case=$label contract=$(cat "$file")" >&2
    return 1
  fi
}

expect_tamper_rejected() {
  local label="$1" file="$2" edit="$3" message="$4"
  shift 4
  cp "$file" "$file.orig"
  perl -pi -e "$edit" "$file"
  expect_rejected "$label" "$message" "$@"
  mv "$file.orig" "$file"
}

@test "open writes a canonical schema 2 plan contract and read returns it" {
  run open_plan
  [ "$status" -eq 0 ]
  [ -f "$PLAN_CONTRACT" ]
  expect_contract plan-contract "$PLAN_CONTRACT" '
    .schema_version == 2 and .created_by == "main" and .project_root == $root
    and .roles == ["coding-dijkstra", "coding-dijkstra-critic"]
    and .state == "planned" and .phase == "09" and .task_name == "write contract"
    and .role == "coding-dijkstra"
    and .files == ["src/contract.py", "tests/task-contract.bats"]
    and .write_allowances == .files
    and (.contract_digest | test("^[0-9a-f]{64}$"))
    and (has("requested_backend") | not)
    and (has("resolved_backend") | not)
    and (has("control_root") | not)
  ' --arg root "$ROOT_CANON"
  run bash "$SCRIPT" read "$ROOT" "$PLAN_ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"state": "planned"'* ]]
}

@test "open rejects invalid plan input" {
  cp "$PLAN" "$ROOT/bad.md"
  perl -pi -e 's#</task>##' "$ROOT/bad.md"
  cp "$PLAN" "$ROOT/dupe.md"
  perl -0777 -pi -e 's#</tasks>#</tasks><tasks></tasks>#' "$ROOT/dupe.md"
  cp "$PLAN" "$ROOT/escape.md"
  perl -pi -e 's#src/contract.py#../escape#' "$ROOT/escape.md"

  expect_rejected unknown-task "unknown task" bash "$SCRIPT" open "$PLAN" "$ROOT" "missing"
  expect_rejected malformed-plan "malformed PLAN" bash "$SCRIPT" open "$ROOT/bad.md" "$ROOT" "write contract"
  expect_rejected duplicate-tasks-block "duplicate tasks" bash "$SCRIPT" open "$ROOT/dupe.md" "$ROOT" "write contract"
  expect_rejected unsafe-path "repo-relative" bash "$SCRIPT" open "$ROOT/escape.md" "$ROOT" "write contract"
}

@test "open rejects injected and unknown option forms" {
  expect_rejected injected-role "invalid role" open_plan --role 'coding-dijkstra;touch /tmp/pwned'
  [ ! -e /tmp/pwned ]
  expect_rejected unknown-flag "Usage" open_plan --bad coding-dijkstra
}

@test "reopen after a transition is idempotent but source drift fails" {
  open_plan
  bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched
  run open_plan
  [ "$status" -eq 0 ]
  perl -pi -e 's/Implement the writer/Changed/' "$PLAN"
  expect_rejected plan-drift "PLAN digest mismatch" open_plan
}

@test "open refuses a symlinked contracts directory" {
  mkdir -p "$ROOT/real-tasks" "$ROOT/.lbwc-planning"
  ln -s "$ROOT/real-tasks" "$ROOT/.lbwc-planning/.contracts"
  expect_rejected symlinked-contracts "symlink" open_plan
}

@test "state applies a legal transition and persists it" {
  open_plan
  run bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" read "$ROOT" "$PLAN_ID"
  [[ "$output" == *'"state": "dispatched"'* ]]
}

@test "state rejects each class of illegal transition" {
  open_plan
  expect_rejected skipped-step "illegal state transition" bash "$SCRIPT" state "$ROOT" "$PLAN_ID" verified
  expect_rejected unknown-state "invalid state" bash "$SCRIPT" state "$ROOT" "$PLAN_ID" bogus
  expect_rejected unknown-contract "unknown contract" bash "$SCRIPT" state "$ROOT" "no-such-contract" dispatched
  bash "$SCRIPT" state "$ROOT" "$PLAN_ID" cancelled
  expect_rejected leaves-terminal "illegal state transition" bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched
}

@test "state and verify reject tampered contracts and job drift" {
  open_plan
  expect_tamper_rejected schema-version "$PLAN_CONTRACT" \
    's/"schema_version": 2/"schema_version": 99/' "invalid contract" \
    bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched
  expect_tamper_rejected roles-sequence "$PLAN_CONTRACT" \
    's/coding-dijkstra-critic/not-the-configured-critic/' "contract digest mismatch" \
    bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched

  local debug_contract
  debug_contract=$(bash "$SCRIPT" issue "$ROOT" "debug-one" \
    --command debug --role debugger --team solo --job "Find root cause")
  expect_rejected job-drift "job digest mismatch" bash "$SCRIPT" verify "$debug_contract" "$ROOT" --job "Different brief"
  expect_tamper_rejected command-name "$debug_contract" \
    's/"command_name": "debug"/"command_name": "qa"/' "contract digest mismatch" \
    bash "$SCRIPT" verify "$debug_contract" "$ROOT" --job "Find root cause"

  make_control_root team-backend
  local team_contract
  team_contract=$(issue_team team-backend --control-root "$CONTROL_ROOT" \
    --requested-backend tmux --resolved-backend tmux --write-capability directory:src/web)
  expect_tamper_rejected resolved-backend "$team_contract" \
    's/"resolved_backend": "tmux"/"resolved_backend": "in_process"/' "contract digest mismatch" \
    bash "$SCRIPT" verify "$team_contract" "$ROOT"
}

@test "issue writes a command contract with exact team and role allowances" {
  run bash "$SCRIPT" issue "$ROOT" "docs-readme" \
    --command docs --role docs --team solo --job "Update README" \
    --write-allowance README.md
  [ "$status" -eq 0 ]
  expect_contract command-contract "$output" '
    .schema_version == 2
    and .source_kind == "command"
    and .command_name == "docs"
    and .created_by == "main"
    and .project_root == $root
    and .team_mode == "solo"
    and .role == "docs"
    and .roles == ["docs"]
    and .write_allowances == ["README.md"]
    and .allowances_by_role == {docs:["README.md"]}
    and (.contract_digest | test("^[0-9a-f]{64}$"))
  ' --arg root "$ROOT_CANON"
}

@test "repeated command issue creates a new run contract" {
  local first second
  first=$(bash "$SCRIPT" issue "$ROOT" repeat --command qa --role qa --team solo --job "verify")
  second=$(bash "$SCRIPT" issue "$ROOT" repeat --command qa --role qa --team solo --job "verify")
  [ "$first" != "$second" ]
  [ -f "$first" ]
  [ -f "$second" ]
}

@test "open binds a plan grouping with exact allowances per role" {
  run open_plan --role coding-dijkstra --team pair --group implementation \
    --job "Implement the writer" \
    --write-allowance src/contract.py --write-allowance tests/task-contract.bats
  [ "$status" -eq 0 ]
  expect_contract plan-grouping "$output" '
    .schema_version == 2
    and .source_kind == "plan"
    and .team_mode == "pair"
    and .group_name == "implementation"
    and .roles == ["coding-dijkstra", "coding-dijkstra-critic"]
    and .allowances_by_role["coding-dijkstra"] == ["src/contract.py", "tests/task-contract.bats"]
    and .allowances_by_role["coding-dijkstra-critic"] == []
  '
}

@test "allowance validation rejects bad allowances before any contract is written" {
  local protected
  expect_rejected role-outside-team "allowance role is not in contract team" \
    bash "$SCRIPT" issue "$ROOT" "bad-team" \
    --command build --role python-engineer --team pair --job "Implement" \
    --role-write-allowance test-dev:tests/unit.py
  expect_rejected outside-plan "allowance is not declared by PLAN" \
    open_plan --role coding-dijkstra --team pair --group outside \
    --job "Implement" --write-allowance src/not-in-plan.py
  for protected in \
    config/subagent-critical-execution.txt \
    config/destructive-commands.txt \
    scripts/file-guard.sh \
    scripts/task-contract.sh \
    scripts/agent-lifecycle.sh \
    .lbwc-planning/.agent-manifest.json \
    .lbwc-planning/.contracts/tasks/forged.json \
    .claude/agents/forged.md
  do
    expect_rejected "protected-$protected" "protected path" \
      bash "$SCRIPT" issue "$ROOT" "protected" \
      --command test --role python-engineer --team solo --job "mutate policy" \
      --write-allowance "$protected"
  done
  [ -z "$(written_contracts)" ]
}

@test "issue writes schema 3 typed capabilities in an explicit control root" {
  make_control_root team-one
  run issue_team team-scope --control-root "$CONTROL_ROOT" \
    --write-capability file:src/web/index.ts --write-capability directory:tests/web
  [ "$status" -eq 0 ]
  [ "$output" = "$CONTROL_ROOT/contracts/tasks/$(basename "$output")" ]
  expect_contract typed-contract "$output" '
    .schema_version == 3
    and .control_root == $control
    and .capabilities_by_role["web-engineer"] == [
      {access:"write",kind:"file",path:"src/web/index.ts"},
      {access:"write",kind:"directory",path:"tests/web"}
    ]
    and .write_allowances == ["src/web/index.ts", "tests/web"]
    and .runtime_kind == "native-team"
    and .communication_policy == "native-team"
    and .requested_backend == "in_process"
    and .resolved_backend == "in_process"
  ' --arg control "$CONTROL_ROOT"
}

@test "schema 3 state updates use the temporary control root only" {
  make_control_root team-state
  local contract
  contract=$(issue_team team-state --control-root "$CONTROL_ROOT" --write-capability directory:src/web)

  run bash "$SCRIPT" state "$ROOT" "$(basename "$contract" .json)" dispatched

  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/.lbwc-planning" ]
  [ ! -e "$CONTROL_ROOT/contracts/.lock" ]
}

@test "schema 3 issue accepts a role with no write capability when the role never writes" {
  make_control_root read-only
  run bash "$SCRIPT" issue "$ROOT" "qa-scope" \
    --command qa --role qa --team solo --job "verify the web scope" \
    --control-root "$CONTROL_ROOT" --requested-backend workflow --resolved-backend workflow
  [ "$status" -eq 0 ]
  expect_contract role-disallows-write "$output" '.schema_version == 3 and .capabilities_by_role["qa"] == []'

  run bash "$SCRIPT" issue "$ROOT" "scout-scope" \
    --command map --role scout --team solo --job "map the thing" \
    --control-root "$CONTROL_ROOT" --requested-backend workflow --resolved-backend workflow \
    --read-only-role scout
  [ "$status" -eq 0 ]
  expect_contract declared-read-only "$output" '.schema_version == 3 and .capabilities_by_role["scout"] == []'
}

@test "schema 3 issue rejects invalid capability and metadata declarations" {
  make_control_root invalid
  local backend=(--requested-backend workflow --resolved-backend workflow)
  expect_rejected writer-without-capability "typed contract requires at least one capability" \
    bash "$SCRIPT" issue "$ROOT" "dev-scope" \
    --command fix --role coding-dijkstra --team solo --job "fix the thing" \
    --control-root "$CONTROL_ROOT" "${backend[@]}"
  expect_rejected read-only-outside-team "read-only role is not in contract team" \
    bash "$SCRIPT" issue "$ROOT" "scout-bad" \
    --command map --role scout --team solo --job "map the thing" \
    --control-root "$CONTROL_ROOT" "${backend[@]}" --read-only-role architect
  expect_rejected read-only-with-write "role declared read-only cannot also receive a write capability" \
    bash "$SCRIPT" issue "$ROOT" "scout-conflict" \
    --command map --role scout --team solo --job "map the thing" \
    --control-root "$CONTROL_ROOT" "${backend[@]}" \
    --read-only-role scout --write-capability file:notes.md
  expect_rejected root-capability-outside-team "repository root capability is only valid for team" \
    bash "$SCRIPT" issue "$ROOT" "not-team" \
    --command test --role web-engineer --team solo --job "scope" \
    --write-capability directory:.
  expect_rejected unknown-runtime-kind "runtime_kind" \
    issue_team bad-runtime --control-root "$CONTROL_ROOT" \
    --runtime-kind unknown-runtime --write-capability directory:src/web
  expect_rejected unknown-communication-policy "communication_policy" \
    issue_team bad-communication --control-root "$CONTROL_ROOT" \
    --communication-policy unknown-policy --write-capability directory:src/web
}

@test "open writes schema 3 when backend and control-root flags are set" {
  make_control_root plan-schema3
  run open_plan --requested-backend tmux --resolved-backend tmux --control-root "$CONTROL_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$CONTROL_ROOT/contracts/tasks/$(basename "$output")" ]
  expect_contract plan-schema3 "$output" '
    .schema_version == 3
    and .source_kind == "plan"
    and .requested_backend == "tmux"
    and .resolved_backend == "tmux"
    and .control_root == $control
    and .runtime_kind == "native-team"
    and .communication_policy == "native-team"
    and .capabilities_by_role["coding-dijkstra"] == [
      {access:"write",kind:"file",path:"src/contract.py"},
      {access:"write",kind:"file",path:"tests/task-contract.bats"}
    ]
    and .write_allowances == ["src/contract.py", "tests/task-contract.bats"]
  ' --arg control "$CONTROL_ROOT"
}

@test "open rejects a partial schema 3 flag set before writing" {
  make_control_root plan-partial
  expect_rejected backends-without-control-root "schema 3 open requires" open_plan --requested-backend tmux --resolved-backend tmux
  expect_rejected control-root-without-backends "schema 3 open requires" open_plan --control-root "$CONTROL_ROOT"
  [ -z "$(written_contracts)" ]
}

@test "assert-snapshot accepts a matching snapshot and rejects a mismatch without writing" {
  make_control_root snapshot-assert
  local full="$ROOT/full-snapshot.json" freeze="$ROOT/freeze-snapshot.json"
  jq -n --arg root "$CONTROL_ROOT" '{requested_backend:"tmux",resolved_backend:"tmux",control_root:$root}' > "$full"
  jq -n '{requested_backend:"tmux",resolved_backend:"tmux"}' > "$freeze"
  local flags=(--requested-backend tmux --resolved-backend tmux --control-root "$CONTROL_ROOT")

  run open_plan "${flags[@]}" --assert-snapshot "$full"
  [ "$status" -eq 0 ]
  expect_contract open-full-snapshot "$output" '.schema_version == 3 and .requested_backend == "tmux" and .resolved_backend == "tmux"'
  run issue_team team-assert "${flags[@]}" --assert-snapshot "$full" --write-capability directory:src/web
  [ "$status" -eq 0 ]
  expect_contract issue-full-snapshot "$output" '.schema_version == 3 and .requested_backend == "tmux" and .resolved_backend == "tmux"'
  run open_plan "${flags[@]}" --assert-snapshot "$freeze" --group freeze-shape
  [ "$status" -eq 0 ]
  expect_contract open-freeze-snapshot "$output" '.schema_version == 3 and .requested_backend == "tmux" and .resolved_backend == "tmux"'

  jq '.requested_backend = "in_process" | .resolved_backend = "in_process"' "$full" > "$ROOT/full-mismatch.json"
  jq '.resolved_backend = "in_process"' "$freeze" > "$ROOT/freeze-mismatch.json"
  expect_rejected open-full-mismatch "snapshot backend mismatch" open_plan "${flags[@]}" --assert-snapshot "$ROOT/full-mismatch.json" --group mismatch
  expect_rejected issue-full-mismatch "snapshot backend mismatch" issue_team team-assert-mismatch "${flags[@]}" \
    --assert-snapshot "$ROOT/full-mismatch.json" --write-capability directory:src/web
  expect_rejected open-freeze-mismatch "snapshot backend mismatch" open_plan "${flags[@]}" --assert-snapshot "$ROOT/freeze-mismatch.json" --group freeze-mismatch
  [ -z "$(find "$CONTROL_ROOT/contracts/tasks" -name '*mismatch*' -print -quit)" ]
}
