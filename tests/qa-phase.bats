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

copy_plugin() {
  PLUGIN="$WORLD/plugin-$1"
  mkdir -p "$PLUGIN"
  cp -R "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/hooks" "$PROJECT_ROOT/templates" "$PROJECT_ROOT/config" "$PLUGIN/"
}

intercept_script() {
  local name="$1" condition="$2" token="$3" script="$PLUGIN/scripts/$1"
  mv "$script" "$script-real"
  printf '#!/bin/bash\n%s && { printf "%%s\\n" %s; exit 1; }\nexec /bin/bash "$(dirname "$0")/%s-real" "$@"\n' \
    "$condition" "$token" "$name" > "$script"
}

stub_qa_route() {
  printf '#!/bin/bash\nprintf "%%s\\n" %s\n' "'{\"model\":\"opus\"}'" > "$PLUGIN/scripts/meridian-routing.sh"
}

copy_plugin_with_offline_models() {
  copy_plugin offline-models
  stub_qa_route
  intercept_script meridian-model true refresh-offline-token
}

copy_plugin_with_online_models() {
  copy_plugin online-models
  stub_qa_route
  printf '#!/bin/bash\nexit 0\n' > "$PLUGIN/scripts/meridian-model"
}

qa_in_repo() {
  (cd "$REPO" && python3 -I -B "$PLUGIN/scripts/qa-phase.py" "$@" 2> "$STDERR_FILE")
}

start_contract() {
  qa_in_repo start "$1" "$2" codex | jq -r '.contract_id'
}

contract_field() {
  bash "$PLUGIN/scripts/task-contract.sh" read "$REPO" "$1" | jq -r --arg field "$2" '.[$field]'
}

contract_count() {
  find "$REPO/.meridian/.contracts/tasks" -name 'cmd-qa-qa-*.json' -type f 2> /dev/null | wc -l | tr -d ' '
}

forge_contract_with_job_of() {
  local phase="$1" source="$2" action contract
  action=$(contract_field "$source" action)
  contract=$(bash "$PLUGIN/scripts/task-contract.sh" issue "$REPO" "qa-$phase-0123456789ab" \
    --command qa --role qa --team solo --group phase --job "$action")
  contract=$(basename "$contract" .json)
  bash "$PLUGIN/scripts/task-contract.sh" state "$REPO" "$contract" dispatched > /dev/null
  printf '%s\n' "$contract"
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

rejected_verdict() {
  verdict deep FAIL | jq -c 'del(.payload.checks_detail[0].description)'
}

publish_rejected_verdict() {
  qa_in_repo publish 1 "$1" "$(rejected_verdict)" > /dev/null || [ "$?" -eq 1 ]
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
  actual=$(contract_field "$contract" state)
  [ "$actual" = "$want" ] || record_case_failure "$label" "contract $contract state=$actual want=$want"
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

expect_no_file() {
  [ ! -e "$2" ] || record_case_failure "$1" "unexpected file $2"
}

expect_replaced_contract() {
  local label="$1" old="$2" reason="$3" fresh
  expect_stdout_json "$label-fresh-id" \
    '(.contract_id | test("^cmd-qa-qa-01-[0-9a-f]{12}-phase$")) and .contract_id != $old' --arg old "$old"
  fresh=$(jq -r '.contract_id // empty' <<< "$output" 2> /dev/null)
  expect_state "$label-fresh-dispatched" "$fresh" dispatched
  expect_state "$label-old-blocked" "$old" blocked
  expect_stderr_has "$label-names-old" "$old"
  expect_stderr_has "$label-gives-reason" "$reason"
  expect_contract_count "$label-two-contracts" 2
}

mark_running() {
  bash "$PLUGIN/scripts/task-contract.sh" state "$REPO" "$1" running > /dev/null
}

age_contract_file() {
  touch -t 200001010000 "$REPO/.meridian/.contracts/tasks/$1.json"
}

block_contract_on_first_read() {
  local script="$PLUGIN/scripts/task-contract.sh"
  mv "$script" "$script-real"
  printf '%s\n' '#!/bin/bash' \
    'real="$(dirname "$0")/task-contract.sh-real"' \
    'marker="$2/.meridian/parallel-start-done"' \
    '[ "$1" = read ] && [ ! -e "$marker" ] && : > "$marker" && /bin/bash "$real" "$@" && exec /bin/bash "$real" state "$2" "$3" blocked > /dev/null' \
    'exec /bin/bash "$real" "$@"' > "$script"
}

expect_verification_frontmatter() {
  local label="$1" matched
  matched=$(grep -cxE 'phase: 01|result: PASS|writer: write-verification.sh|  - 01-01' "$PHASE_DIR/01-VERIFICATION.md")
  [ "$matched" = 4 ] || record_case_failure "$label" "matched $matched of 4 frontmatter lines"
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

@test "start reuses a matching dispatched contract, refuses while a live worker runs and retires a stale or mismatched contract to blocked" {
  local first
  new_project start
  run qa_in_repo start 1 standard codex
  expect_stdout_json start-issues-contract '
    (.contract_id | test("^cmd-qa-qa-01-[0-9a-f]{12}-phase$"))
    and .agent == {agent_type: "meridian-qa"} and .phase == "01"'
  expect_stdout_json codex-catalog-not-stale '.catalog_stale == false'
  expect_state start-contract-dispatched "$(jq -r '.contract_id' <<< "$output")" dispatched
  expect_contract_count start-writes-one-contract 1

  new_project same-job
  first=$(start_contract 1 standard)
  run qa_in_repo start 1 standard codex
  expect_stdout_json same-job-reuses-contract '.contract_id == $id' --arg id "$first"
  expect_state same-job-contract-stays-dispatched "$first" dispatched
  expect_contract_count same-job-writes-no-contract 1

  new_project other-tier
  first=$(start_contract 1 standard)
  run qa_in_repo start 1 deep codex
  expect_replaced_contract other-tier "$first" "because a new run started"

  new_project other-commit
  first=$(start_contract 1 standard)
  next_commit second
  run qa_in_repo start 1 standard codex
  expect_replaced_contract other-commit "$first" "because a new run started"

  new_project live-running
  first=$(start_contract 1 standard)
  mark_running "$first"
  run qa_in_repo start 1 standard codex
  expect_case_silent live-running-refused 1
  expect_stderr_has live-running-names-contract "$first"
  expect_stderr_has live-running-gives-age "running for 0 minutes"
  expect_stderr_has live-running-gives-retry "after 60 minutes"
  expect_state live-running-stays-running "$first" running
  expect_contract_count live-running-writes-no-contract 1

  new_project stale-running
  first=$(start_contract 1 standard)
  mark_running "$first"
  age_contract_file "$first"
  run qa_in_repo start 1 standard codex
  expect_replaced_contract stale-running "$first" "stale for"

  new_project stale-limit-zero
  first=$(start_contract 1 standard)
  mark_running "$first"
  MERIDIAN_QA_STALE_MINUTES=0 run qa_in_repo start 1 standard codex
  expect_replaced_contract stale-limit-zero "$first" "stale for 0 minutes"

  copy_plugin parallel-start
  block_contract_on_first_read
  new_project already-blocked
  first=$(start_contract 1 standard)
  run qa_in_repo start 1 deep codex
  expect_stdout_json already-blocked-issues-fresh-contract \
    '(.contract_id | test("^cmd-qa-qa-01-[0-9a-f]{12}-phase$")) and .contract_id != $old' --arg old "$first"
  expect_state already-blocked-old-stays-blocked "$first" blocked
  expect_contract_count already-blocked-two-contracts 2

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
  expect_verification_frontmatter pass-verification-frontmatter
  expect_no_file pass-no-remediation "$PHASE_DIR/remediation/qa/.qa-remediation-stage"

  new_project verified-then-start
  contract=$(start_contract 1 standard)
  qa_in_repo publish 1 "$contract" "$(verdict standard PASS)" > /dev/null
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
  forged=$(forge_contract_with_job_of 02 "$(start_contract 1 standard)")
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

@test "start on the Claude host reports catalog_stale after a failed refresh, uses the saved catalog and stops when the project has no saved catalog" {
  copy_plugin_with_offline_models
  new_project saved-catalog
  printf '{"agent_model_ids":{"opus":"claude-opus-fixture"}}\n' > "$REPO/.meridian/claude-capabilities.json"
  run qa_in_repo start 1 standard claude
  expect_stdout_json saved-catalog-maps-model '.agent == {subagent_type: "meridian:phase-qa", model: "claude-opus-fixture"}'
  expect_stdout_json saved-catalog-is-stale '.catalog_stale == true'
  expect_stderr_has saved-catalog-warns-with-refresh-error refresh-offline-token
  expect_contract_count saved-catalog-issues-contract 1

  new_project no-catalog
  run qa_in_repo start 1 standard claude
  expect_refused no-catalog
  expect_stderr_has no-catalog-names-catalog claude-capabilities.json
  expect_stderr_has no-catalog-carries-refresh-error refresh-offline-token
  expect_contract_count no-catalog-no-contract 0

  copy_plugin_with_online_models
  new_project refreshed-catalog
  printf '{"agent_model_ids":{"opus":"claude-opus-fixture"}}\n' > "$REPO/.meridian/claude-capabilities.json"
  run qa_in_repo start 1 standard claude
  expect_stdout_json refreshed-catalog-not-stale '.catalog_stale == false and .agent.model == "claude-opus-fixture"'

  assert_no_case_failures
}

@test "publish skips a missing STATE.md or Todos section, blocks the contract when a step fails and keeps both errors when blocking fails too" {
  local contract
  new_project no-state-file
  rm "$REPO/.meridian/STATE.md"
  next_commit drop-state
  contract=$(start_contract 1 standard)
  run qa_in_repo publish 1 "$contract" "$(verdict standard PASS)"
  expect_stdout_json no-state-file-routes-to-uat '.routing == "PROCEED_TO_UAT" and .contract_id == $id' --arg id "$contract"
  expect_state no-state-file-contract-verified "$contract" verified

  new_project no-todos-section
  printf '# State\n\nNo open work.\n' > "$REPO/.meridian/STATE.md"
  next_commit drop-todos
  contract=$(start_contract 1 standard)
  run qa_in_repo publish 1 "$contract" "$(verdict standard PASS)"
  expect_stdout_json no-todos-section-routes-to-uat '.routing == "PROCEED_TO_UAT" and .contract_id == $id' --arg id "$contract"
  expect_state no-todos-section-contract-verified "$contract" verified

  new_project rejected-verdict
  contract=$(start_contract 1 deep)
  run qa_in_repo publish 1 "$contract" "$(rejected_verdict)"
  expect_refused rejected-verdict
  expect_state rejected-verdict-contract-blocked "$contract" blocked

  new_project rejected-then-start
  contract=$(start_contract 1 deep)
  publish_rejected_verdict "$contract"
  run qa_in_repo start 1 deep codex
  expect_stdout_json rejected-verdict-next-start-mints-contract \
    '(.contract_id | test("^cmd-qa-qa-01-[0-9a-f]{12}-phase$")) and .contract_id != $id' --arg id "$contract"
  expect_contract_count rejected-verdict-two-contracts 2

  copy_plugin malformed-registry
  intercept_script track-known-issues.sh '[ "$1" = promote-todos ]' promote_status=malformed_registry
  new_project malformed-registry
  contract=$(start_contract 1 standard)
  run qa_in_repo publish 1 "$contract" "$(verdict standard PASS)"
  expect_refused malformed-registry
  expect_stderr_has malformed-registry-reports-status malformed_registry
  expect_state malformed-registry-contract-blocked "$contract" blocked

  copy_plugin chained-error
  intercept_script write-verification.sh true verdict-writer-token
  intercept_script task-contract.sh '[ "$1" = state ] && [ "$4" = blocked ]' blocked-transition-token
  new_project chained-error
  contract=$(start_contract 1 standard)
  run qa_in_repo publish 1 "$contract" "$(verdict standard PASS)"
  expect_refused chained-error
  expect_stderr_has chained-error-keeps-publish-error verdict-writer-token
  expect_stderr_has chained-error-adds-transition-error blocked-transition-token
  expect_stderr_has chained-error-says-block-failed "also failed to move to blocked"

  assert_no_case_failures
}
