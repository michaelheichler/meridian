#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper

setup() {
  ROOT="$(mktemp -d)"
  ROOT_CANON="$(cd "$ROOT" && pwd -P)"
  PLAN="$ROOT/PLAN.md"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/task-contract.sh"
  PLAN_CONTRACT="$ROOT/.lbwc-planning/.contracts/tasks/09-PLAN-write-contract.json"
  PLAN_ID="09-PLAN-write-contract"
  reset_case_failures
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
  [ "$status" -ne 0 ] || record_case_failure "$label" "expected a failing status output=$output"
  [[ "$output" == *"$message"* ]] || record_case_failure "$label" "missing message=[$message] output=$output"
}

expect_contract() {
  local label="$1" file="$2" filter="$3"
  shift 3
  jq -e "$@" "$filter" "$file" >/dev/null 2>&1 \
    || record_case_failure "$label" "contract did not satisfy filter content=$(cat "$file" 2>&1)"
}

expect_accepted() {
  local label="$1"
  [ "$status" -eq 0 ] || record_case_failure "$label" "status=$status output=$output"
}

expect_no_written_contracts() {
  [ -z "$(written_contracts)" ] || record_case_failure "$1" "contracts were written: $(written_contracts)"
}

expect_tamper_rejected() {
  local label="$1" file="$2" edit="$3" message="$4"
  shift 4
  cp "$file" "$file.orig"
  perl -pi -e "$edit" "$file"
  expect_rejected "$label" "$message" "$@"
  mv "$file.orig" "$file"
}

contract_open_plan() {
  mkdir -p "$ROOT/real-tasks" "$ROOT/.lbwc-planning"
  ln -s "$ROOT/real-tasks" "$ROOT/.lbwc-planning/.contracts"
  expect_rejected symlinked-contracts "symlink" open_plan
  rm "$ROOT/.lbwc-planning/.contracts"

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

  expect_rejected injected-role "invalid role" open_plan --role 'coding-dijkstra;touch /tmp/pwned'
  [ ! -e /tmp/pwned ] || record_case_failure injected-role "/tmp/pwned exists"
  expect_rejected unknown-flag "Usage" open_plan --bad coding-dijkstra

  run open_plan
  expect_accepted plan-contract
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
  expect_case read-plan-contract 0 '"state": "planned"'

  run open_plan --role coding-dijkstra --team pair --group implementation \
    --job "Implement the writer" \
    --write-allowance src/contract.py --write-allowance tests/task-contract.bats
  expect_accepted plan-grouping
  expect_contract plan-grouping "$output" '
    .schema_version == 2
    and .source_kind == "plan"
    and .team_mode == "pair"
    and .group_name == "implementation"
    and .roles == ["coding-dijkstra", "coding-dijkstra-critic"]
    and .allowances_by_role["coding-dijkstra"] == ["src/contract.py", "tests/task-contract.bats"]
    and .allowances_by_role["coding-dijkstra-critic"] == []
  '

  bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched
  run open_plan
  expect_accepted reopen-after-transition
  perl -pi -e 's/Implement the writer/Changed/' "$PLAN"
  expect_rejected plan-drift "PLAN digest mismatch" open_plan

  assert_no_case_failures
}

contract_state_transitions() {
  open_plan
  expect_rejected skipped-step "illegal state transition" bash "$SCRIPT" state "$ROOT" "$PLAN_ID" verified
  expect_rejected unknown-state "invalid state" bash "$SCRIPT" state "$ROOT" "$PLAN_ID" bogus
  expect_rejected unknown-contract "unknown contract" bash "$SCRIPT" state "$ROOT" "no-such-contract" dispatched
  expect_tamper_rejected schema-version "$PLAN_CONTRACT" \
    's/"schema_version": 2/"schema_version": 99/' "invalid contract" \
    bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched
  expect_tamper_rejected roles-sequence "$PLAN_CONTRACT" \
    's/coding-dijkstra-critic/not-the-configured-critic/' "contract digest mismatch" \
    bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched

  run bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched
  expect_accepted legal-transition
  run bash "$SCRIPT" read "$ROOT" "$PLAN_ID"
  expect_case legal-transition-persisted 0 '"state": "dispatched"'

  bash "$SCRIPT" state "$ROOT" "$PLAN_ID" cancelled
  expect_rejected leaves-terminal "illegal state transition" bash "$SCRIPT" state "$ROOT" "$PLAN_ID" dispatched

  assert_no_case_failures
}

contract_verify_drift() {
  local debug_contract team_contract
  debug_contract=$(bash "$SCRIPT" issue "$ROOT" "debug-one" \
    --command debug --role debugger --team solo --job "Find root cause")
  expect_rejected job-drift "job digest mismatch" bash "$SCRIPT" verify "$debug_contract" "$ROOT" --job "Different brief"
  expect_tamper_rejected command-name "$debug_contract" \
    's/"command_name": "debug"/"command_name": "qa"/' "contract digest mismatch" \
    bash "$SCRIPT" verify "$debug_contract" "$ROOT" --job "Find root cause"

  make_control_root team-backend
  team_contract=$(issue_team team-backend --control-root "$CONTROL_ROOT" \
    --requested-backend tmux --resolved-backend tmux --write-capability directory:src/web)
  expect_tamper_rejected resolved-backend "$team_contract" \
    's/"resolved_backend": "tmux"/"resolved_backend": "in_process"/' "contract digest mismatch" \
    bash "$SCRIPT" verify "$team_contract" "$ROOT"

  assert_no_case_failures
}

contract_issue_exact_allowances() {
  local protected first second
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
  expect_no_written_contracts bad-allowances-write-nothing

  run bash "$SCRIPT" issue "$ROOT" "docs-readme" \
    --command docs --role docs --team solo --job "Update README" \
    --write-allowance README.md
  expect_accepted command-contract
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

  first=$(bash "$SCRIPT" issue "$ROOT" repeat --command qa --role qa --team solo --job "verify")
  second=$(bash "$SCRIPT" issue "$ROOT" repeat --command qa --role qa --team solo --job "verify")
  [ "$first" != "$second" ] || record_case_failure repeated-issue "both runs returned $first"
  [ -f "$first" ] || record_case_failure repeated-issue "missing first contract $first"
  [ -f "$second" ] || record_case_failure repeated-issue "missing second contract $second"

  assert_no_case_failures
}

contract_issue_typed_capabilities() {
  local contract backend=(--requested-backend workflow --resolved-backend workflow)
  make_control_root team-state
  contract=$(issue_team team-state --control-root "$CONTROL_ROOT" --write-capability directory:src/web)
  run bash "$SCRIPT" state "$ROOT" "$(basename "$contract" .json)" dispatched
  expect_accepted schema3-state
  [ ! -e "$ROOT/.lbwc-planning" ] || record_case_failure schema3-state "planning directory was created"
  [ ! -e "$CONTROL_ROOT/contracts/.lock" ] || record_case_failure schema3-state "control root lock remained"

  make_control_root team-one
  run issue_team team-scope --control-root "$CONTROL_ROOT" \
    --write-capability file:src/web/index.ts --write-capability directory:tests/web
  expect_accepted typed-contract
  [ "$output" = "$CONTROL_ROOT/contracts/tasks/$(basename "$output")" ] \
    || record_case_failure typed-contract "contract path $output is outside the control root"
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

  make_control_root read-only
  run bash "$SCRIPT" issue "$ROOT" "qa-scope" \
    --command qa --role qa --team solo --job "verify the web scope" \
    --control-root "$CONTROL_ROOT" "${backend[@]}"
  expect_accepted role-disallows-write
  expect_contract role-disallows-write "$output" '.schema_version == 3 and .capabilities_by_role["qa"] == []'
  run bash "$SCRIPT" issue "$ROOT" "scout-scope" \
    --command map --role scout --team solo --job "map the thing" \
    --control-root "$CONTROL_ROOT" "${backend[@]}" \
    --read-only-role scout
  expect_accepted declared-read-only
  expect_contract declared-read-only "$output" '.schema_version == 3 and .capabilities_by_role["scout"] == []'

  make_control_root invalid
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

  assert_no_case_failures
}

contract_open_typed_capabilities() {
  make_control_root plan-partial
  expect_rejected backends-without-control-root "schema 3 open requires" open_plan --requested-backend tmux --resolved-backend tmux
  expect_rejected control-root-without-backends "schema 3 open requires" open_plan --control-root "$CONTROL_ROOT"
  expect_no_written_contracts partial-flags-write-nothing

  make_control_root plan-schema3
  run open_plan --requested-backend tmux --resolved-backend tmux --control-root "$CONTROL_ROOT"
  expect_accepted plan-schema3
  [ "$output" = "$CONTROL_ROOT/contracts/tasks/$(basename "$output")" ] \
    || record_case_failure plan-schema3 "contract path $output is outside the control root"
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

  assert_no_case_failures
}

@test "task contracts preserve plan, command, capability, transition and snapshot constraints" {
  run_scenario_cases contract_open_plan contract_state_transitions contract_verify_drift \
    contract_issue_exact_allowances contract_issue_typed_capabilities \
    contract_open_typed_capabilities contract_assert_snapshot
}

contract_assert_snapshot() {
  make_control_root snapshot-assert
  local full="$ROOT/full-snapshot.json" freeze="$ROOT/freeze-snapshot.json"
  jq -n --arg root "$CONTROL_ROOT" '{requested_backend:"tmux",resolved_backend:"tmux",control_root:$root}' > "$full"
  jq -n '{requested_backend:"tmux",resolved_backend:"tmux"}' > "$freeze"
  local flags=(--requested-backend tmux --resolved-backend tmux --control-root "$CONTROL_ROOT")

  run open_plan "${flags[@]}" --assert-snapshot "$full"
  expect_accepted open-full-snapshot
  expect_contract open-full-snapshot "$output" '.schema_version == 3 and .requested_backend == "tmux" and .resolved_backend == "tmux"'
  run issue_team team-assert "${flags[@]}" --assert-snapshot "$full" --write-capability directory:src/web
  expect_accepted issue-full-snapshot
  expect_contract issue-full-snapshot "$output" '.schema_version == 3 and .requested_backend == "tmux" and .resolved_backend == "tmux"'
  run open_plan "${flags[@]}" --assert-snapshot "$freeze" --group freeze-shape
  expect_accepted open-freeze-snapshot
  expect_contract open-freeze-snapshot "$output" '.schema_version == 3 and .requested_backend == "tmux" and .resolved_backend == "tmux"'

  jq '.requested_backend = "in_process" | .resolved_backend = "in_process"' "$full" > "$ROOT/full-mismatch.json"
  jq '.resolved_backend = "in_process"' "$freeze" > "$ROOT/freeze-mismatch.json"
  expect_rejected open-full-mismatch "snapshot backend mismatch" open_plan "${flags[@]}" --assert-snapshot "$ROOT/full-mismatch.json" --group mismatch
  expect_rejected issue-full-mismatch "snapshot backend mismatch" issue_team team-assert-mismatch "${flags[@]}" \
    --assert-snapshot "$ROOT/full-mismatch.json" --write-capability directory:src/web
  expect_rejected open-freeze-mismatch "snapshot backend mismatch" open_plan "${flags[@]}" --assert-snapshot "$ROOT/freeze-mismatch.json" --group freeze-mismatch
  [ -z "$(find "$CONTROL_ROOT/contracts/tasks" -name '*mismatch*' -print -quit)" ] \
    || record_case_failure mismatch-writes-nothing "a mismatch contract was written"

  assert_no_case_failures
}
