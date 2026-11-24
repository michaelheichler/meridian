#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  reset_case_failures
  WORLD="$(mktemp -d)"
  WORLD="$(cd "$WORLD" && pwd -P)"
  PLUGIN="$PROJECT_ROOT"
  STDERR_FILE="$WORLD/runner.stderr"
}

teardown() {
  rm -rf "$WORLD"
}

write_phase() {
  local dir="$1" number="$2"
  mkdir -p "$dir"
  printf -- '---\nphase: %s\nplan: 01\n---\nBuild the app.\n' "$number" > "$dir/$number-01-PLAN.md"
  printf -- '---\nphase: %s\nplan: 01\nstatus: complete\n---\nBuilt the app.\n' "$number" > "$dir/$number-01-SUMMARY.md"
}

first_commit() {
  local tree commit
  git -C "$REPO" add -A
  tree=$(git -C "$REPO" write-tree)
  commit=$(git -C "$REPO" commit-tree "$tree" -m init)
  git -C "$REPO" update-ref HEAD "$commit"
}

next_commit() {
  local tree commit
  printf '%s\n' "$1" >> "$REPO/app.txt"
  git -C "$REPO" add -A
  tree=$(git -C "$REPO" write-tree)
  commit=$(git -C "$REPO" commit-tree "$tree" -p "$(git -C "$REPO" rev-parse HEAD)" -m "$1")
  git -C "$REPO" update-ref HEAD "$commit"
}

new_project() {
  REPO="$WORLD/$1"
  PHASE_DIR="$REPO/.meridian/phases/01-setup"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Meridian Test"
  git -C "$REPO" config user.email meridian-tests@example.com
  write_phase "$PHASE_DIR" 01
  printf '# State\n\n## Todos\n\nNone.\n' > "$REPO/.meridian/STATE.md"
  printf 'app\n' > "$REPO/app.txt"
  first_commit
}

copy_plugin_with_stubbed_models() {
  PLUGIN="$WORLD/plugin"
  mkdir -p "$PLUGIN"
  cp -R "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/hooks" "$PROJECT_ROOT/templates" "$PROJECT_ROOT/config" "$PLUGIN/"
  printf '#!/bin/bash\nprintf "%%s\\n" refresh-offline-token >&2\nexit 1\n' > "$PLUGIN/scripts/meridian-model"
  printf '#!/bin/bash\nprintf "%%s\\n" %s\n' "'{\"model\":\"opus\"}'" > "$PLUGIN/scripts/meridian-routing.sh"
}

qa_in_repo() {
  (cd "$REPO" && python3 -I -B "$PLUGIN/scripts/qa-phase.py" "$@" 2> "$STDERR_FILE")
}

start_contract() {
  qa_in_repo start "$1" "$2" codex | jq -r '.contract_id'
}

contract_state() {
  bash "$PLUGIN/scripts/task-contract.sh" read "$REPO" "$1" | jq -r '.state'
}

contract_count() {
  find "$REPO/.meridian/.contracts/tasks" -name 'cmd-qa-qa-*.json' -type f 2> /dev/null | wc -l | tr -d ' '
}

verdict() {
  jq -cn --arg tier "$1" --arg result "$2" '{
    type: "qa_verdict", author_role: "qa", phase: "1",
    payload: {
      tier: $tier, result: $result,
      checks: {passed: (if $result == "PASS" then 1 else 0 end), failed: (if $result == "PASS" then 0 else 1 end), total: 1},
      checks_detail: [{id: "C1", status: $result, plan_ref: "01-01", description: "Run the app build", evidence: "fixture build log"}],
      plans_verified: ["01-01"]
    }
  }'
}

expect_stdout_json() {
  local label="$1" filter="$2"
  shift 2
  jq -e "$@" "$filter" <<< "$output" > /dev/null 2>&1 \
    || record_case_failure "$label" "stdout failed filter status=$status output=$output stderr=$(cat "$STDERR_FILE")"
}

expect_stderr_has() {
  local label="$1" token="$2"
  [[ "$(cat "$STDERR_FILE")" == *"$token"* ]] \
    || record_case_failure "$label" "stderr lacks [$token] stderr=$(cat "$STDERR_FILE")"
}

expect_state() {
  local label="$1" contract="$2" want="$3" actual
  actual=$(contract_state "$contract")
  [ "$actual" = "$want" ] || record_case_failure "$label" "contract state=$actual want=$want"
}

expect_contract_count() {
  local label="$1" want="$2" actual
  actual=$(contract_count)
  [ "$actual" = "$want" ] || record_case_failure "$label" "contract count=$actual want=$want"
}

expect_refused() {
  local label="$1"
  expect_case_silent "$label" 1
  [ -s "$STDERR_FILE" ] || record_case_failure "$label" "refusal left stderr empty"
  [[ "$(cat "$STDERR_FILE")" != *Traceback* ]] || record_case_failure "$label" "crashed stderr=$(cat "$STDERR_FILE")"
}

forge_contract_with_phase_one_job() {
  local action contract
  action=$(bash "$PLUGIN/scripts/task-contract.sh" read "$REPO" "$(start_contract 1 standard)" | jq -r '.action')
  contract=$(bash "$PLUGIN/scripts/task-contract.sh" issue "$REPO" "qa-$1-0123456789ab"     --command qa --role qa --team solo --group phase --job "$action")
  contract=$(basename "$contract" .json)
  bash "$PLUGIN/scripts/task-contract.sh" state "$REPO" "$contract" dispatched > /dev/null
  printf '%s
' "$contract"
}

expect_no_file() {
  [ ! -e "$2" ] || record_case_failure "$1" "unexpected file $2"
}

@test "inspect reports the phase plans and summaries, and route returns the ownership verdict for the owners the caller passes" {
  new_project inspect-fresh
  printf 'Not a plan file.\n' > "$PHASE_DIR/DRAFTPLAN.md"
  run qa_in_repo inspect 1
  expect_stdout_json inspect-fresh '
    .phase == "01" and .phase_dir == $dir
    and .plans == [$dir + "/01-01-PLAN.md"]
    and .summaries == [$dir + "/01-01-SUMMARY.md"]
    and .verification == $dir + "/01-VERIFICATION.md"
    and .task_contracts_present == false' --arg dir "$PHASE_DIR"

  new_project inspect-registry
  mkdir -p "$REPO/.meridian/.contracts/tasks"
  run qa_in_repo inspect 01
  expect_stdout_json inspect-with-contract-registry '.phase == "01" and .task_contracts_present == true'

  new_project route
  printf '{"qa_skip_agents":["backend"]}\n' > "$REPO/.meridian/config.json"
  run qa_in_repo route 1 '[{"task_id":"t1","owners":["backend"]},{"task_id":"t2","owners":["backend","docs"]}]'
  expect_stdout_json route-uses-project-skip-roles '
    [.tasks[] | {task_id, skip_qa}] == [{task_id: "t1", skip_qa: true}, {task_id: "t2", skip_qa: false}]
    and .qa_required == true
    and [.skip_entries[].id] == ["qa-skip-t1"]'

  assert_no_case_failures
}

@test "start issues one dispatched QA contract per tier and commit and stops on an open contract for other work" {
  local first other_tier_contract
  new_project start
  run qa_in_repo start 1 standard codex
  expect_stdout_json start-issues-contract '
    (.contract_id | test("^cmd-qa-qa-01-[0-9a-f]{12}-phase$"))
    and .agent == {agent_type: "meridian-qa"} and .phase == "01"'
  first=$(jq -r '.contract_id' <<< "$output")
  expect_state start-contract-dispatched "$first" dispatched
  expect_contract_count start-writes-one-contract 1

  run qa_in_repo start 1 standard codex
  expect_stdout_json same-job-reuses-contract '.contract_id == $id' --arg id "$first"
  expect_contract_count same-job-writes-no-contract 1

  run qa_in_repo start 1 deep codex
  expect_case_silent other-tier-refused 1
  expect_stderr_has other-tier-names-open-contract "$first"
  expect_contract_count other-tier-writes-no-contract 1

  next_commit second
  run qa_in_repo start 1 standard codex
  expect_case_silent other-commit-refused 1
  expect_stderr_has other-commit-names-open-contract "$first"
  expect_contract_count other-commit-writes-no-contract 1

  assert_no_case_failures
}

@test "publish writes the phase verification and moves the contract to verified on PROCEED_TO_UAT and to blocked with remediation state on REMEDIATION_REQUIRED" {
  local contract
  new_project publish-pass
  contract=$(start_contract 1 standard)
  run qa_in_repo publish 1 "$contract" "$(verdict standard PASS)"
  expect_stdout_json pass-routes-to-uat '
    .routing == "PROCEED_TO_UAT" and .contract_id == $id and .verification == $file' \
    --arg id "$contract" --arg file "$PHASE_DIR/01-VERIFICATION.md"
  expect_state pass-contract-verified "$contract" verified
  run grep -cxE 'phase: 01|result: PASS|writer: write-verification.sh|  - 01-01' "$PHASE_DIR/01-VERIFICATION.md"
  expect_case_exact pass-verification-frontmatter 0 4
  expect_no_file pass-no-remediation "$PHASE_DIR/remediation/qa/.qa-remediation-stage"
  run qa_in_repo start 1 standard codex
  expect_stdout_json closed-contract-not-reused '.contract_id != $id' --arg id "$contract"

  new_project publish-fail
  contract=$(start_contract 1 deep)
  run qa_in_repo publish 1 "$contract" "$(verdict deep FAIL)"
  expect_stdout_json fail-routes-to-remediation '.routing == "REMEDIATION_REQUIRED" and .contract_id == $id' --arg id "$contract"
  expect_state fail-contract-blocked "$contract" blocked
  [ -f "$PHASE_DIR/remediation/qa/.qa-remediation-stage" ] \
    || record_case_failure fail-remediation-initialised "no remediation stage file under $PHASE_DIR"

  assert_no_case_failures
}

@test "the runner refuses a symlinked phase, active remediation, a contract from another phase and a verdict without plans_verified" {
  local contract foreign forged
  new_project symlinked
  mv "$PHASE_DIR" "$WORLD/real-phase"
  ln -s "$WORLD/real-phase" "$PHASE_DIR"
  run qa_in_repo inspect 1
  expect_refused symlinked-phase

  new_project remediating
  mkdir -p "$PHASE_DIR/remediation/qa"
  printf 'stage=plan\nround=01\n' > "$PHASE_DIR/remediation/qa/.qa-remediation-stage"
  run qa_in_repo start 1 standard codex
  expect_refused active-remediation
  expect_contract_count active-remediation-no-contract 0

  new_project foreign
  write_phase "$REPO/.meridian/phases/02-next" 02
  next_commit phase-two
  foreign=$(start_contract 2 standard)
  run qa_in_repo publish 1 "$foreign" "$(verdict standard PASS)"
  expect_refused foreign-contract
  expect_state foreign-contract-untouched "$foreign" dispatched
  expect_no_file foreign-contract-no-verification "$PHASE_DIR/01-VERIFICATION.md"

  new_project forged
  forged=$(forge_contract_with_phase_one_job 02)
  run qa_in_repo publish 1 "$forged" "$(verdict standard PASS)"
  expect_refused forged-contract-id
  expect_state forged-contract-untouched "$forged" dispatched
  expect_no_file forged-contract-no-verification "$PHASE_DIR/01-VERIFICATION.md"

  new_project unverified-plans
  contract=$(start_contract 1 standard)
  run qa_in_repo publish 1 "$contract" "$(verdict standard PASS | jq -c 'del(.payload.plans_verified)')"
  expect_refused missing-plans-verified
  expect_state missing-plans-contract-untouched "$contract" dispatched
  expect_no_file missing-plans-no-verification "$PHASE_DIR/01-VERIFICATION.md"

  assert_no_case_failures
}

@test "a failed Claude capability refresh falls back to the saved catalog and stops start when the project has no saved catalog" {
  copy_plugin_with_stubbed_models

  new_project saved-catalog
  printf '{"agent_model_ids":{"opus":"claude-opus-fixture"}}\n' > "$REPO/.meridian/claude-capabilities.json"
  run qa_in_repo start 1 standard claude
  expect_stdout_json saved-catalog-maps-model '.agent == {subagent_type: "meridian:phase-qa", model: "claude-opus-fixture"}'
  expect_stderr_has saved-catalog-warns-with-refresh-error refresh-offline-token
  expect_contract_count saved-catalog-issues-contract 1

  new_project no-catalog
  run qa_in_repo start 1 standard claude
  expect_refused no-catalog
  expect_stderr_has no-catalog-names-catalog claude-capabilities.json
  expect_stderr_has no-catalog-carries-refresh-error refresh-offline-token
  expect_contract_count no-catalog-no-contract 0

  assert_no_case_failures
}
