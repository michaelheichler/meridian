#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  TRANSACTION="$REPO_ROOT/scripts/team-command-transaction.sh"
  TEST_ROOT="$(mktemp -d)"
  SETTINGS="$TEST_ROOT/settings.json"
  printf '%s\n' '{}' > "$SETTINGS"
  PROJECT="$TEST_ROOT/project"
  mkdir -p "$PROJECT/src" "$TEST_ROOT/claude"
  (cd "$PROJECT" && git init -q)
  export MERIDIAN_SETTINGS_PATH="$SETTINGS"
  export CLAUDE_CONFIG_DIR="$TEST_ROOT/claude"
  unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS || true
  use_claude_fixture "$TEST_ROOT/host-claude"
  reset_case_failures
}

teardown() {
  rm -rf "$TEST_ROOT" 2>/dev/null || { sleep 1; rm -rf "$TEST_ROOT" 2>/dev/null || true; }
}

prepare_run() {
  local run_id="$1"
  shift
  RUN_ID="$run_id"
  MERIDIAN_SETTINGS_PATH="$SETTINGS" run bash "$TRANSACTION" prepare \
    --project-root "$PROJECT" --run-id "$run_id" --instruction "implement scoped change" "$@"
  [ "$status" -eq 0 ]
  CONTRACT_ID=$(jq -r '.contract_id' <<< "$output")
  RUN_ROOT=$(jq -r '.run_root' <<< "$output")
  [ -n "$CONTRACT_ID" ]
  [ -n "$RUN_ROOT" ]
}

rewrite_json() {
  local file="$1" updated
  shift
  updated=$(jq -c "$@" "$file") || return 1
  printf '%s\n' "$updated" > "$file"
}

manifest_set_running() {
  rewrite_json "$RUN_ROOT/agent-manifest.json" '.agents |= with_entries(.value.state = "running")'
}

manifest_bind_task() {
  rewrite_json "$RUN_ROOT/agent-manifest.json" --arg task "$1" --arg contract "$CONTRACT_ID" '
    .tasks = ((.tasks // {}) + {($task): {native_task_id:$task, contract_id:$contract, contract_path:"", contract_digest:"", subject:$contract, state:"created", created_at:"2026-01-01T00:00:00Z"}})
  '
}

retarget_run_backend() {
  local backend="$1" contract_path new_id
  contract_path=$(bash "$REPO_ROOT/scripts/task-contract.sh" issue "$PROJECT" "$RUN_ID-$backend" \
    --command team --role web-engineer --team pair --job retarget --control-root "$RUN_ROOT" \
    --runtime-kind native-team --communication-policy native-team \
    --requested-backend "$backend" --resolved-backend "$backend" \
    --role-write-capability web-engineer:directory:src) || return 1
  new_id=$(basename "$contract_path" .json)
  rewrite_json "$RUN_ROOT/contract.json" --arg id "$new_id" --arg backend "$backend" \
    '.contract_id = $id | .requested_backend = $backend | .resolved_backend = $backend'
  rewrite_json "$RUN_ROOT/run.json" --arg backend "$backend" \
    '.requested_backend = $backend | .resolved_backend = $backend'
  rewrite_json "$RUN_ROOT/agent-manifest.json" --arg id "$new_id" --arg backend "$backend" '
    .agents |= with_entries(.value.contract_id = $id | .value.execution.contract_id = $id
      | .value.execution.requested_backend = $backend | .value.execution.resolved_backend = $backend)
  '
}

record_full_roster() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
      --contract-id "$CONTRACT_ID" --teammate "$name"
    [ "$status" -eq 0 ]
  done < <(jq -r '.teammates[].name' <<< "$output")
}

seed_saved_routing_root() {
  local route_binary="$TEST_ROOT/claude-route-fixture" route_sha
  mkdir -p "$PROJECT/.meridian"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "fixture"' > "$route_binary"
  chmod +x "$route_binary"
  route_sha=$(shasum -a 256 "$route_binary" | awk '{print $1}')
  jq -n --arg binary "$route_binary" --arg sha "$route_sha" '
    {
      schema_version: 1,
      source: {binary_path: $binary, version: "fixture", sha256: $sha, detected_at: "2035-01-02T03:04:05Z"},
      models: [{selector: "nova-route", label: "Nova Route", description: "Fixture selector"}],
      reasoning: {scope: "global", accepted_values: ["deliberate"], model_associations: {"nova-route": ["deliberate"]}}
    }
  ' > "$PROJECT/.meridian/claude-capabilities.json"
  jq --slurpfile defaults "$REPO_ROOT/templates/agent-roles/defaults.json" '
    . + {
      schema_version: 1,
      routing: {
        active_profile: "balanced",
        profiles: {
          quality: {roles: {}},
          balanced: {
            roles: ($defaults[0] | keys | map({key: ., value: {model: "nova-route", reasoning: "deliberate", status: "resolved"}}) | from_entries)
          },
          turbo: {roles: {}}
        }
      }
    }
  ' "$REPO_ROOT/config/settings.json" > "$PROJECT/.meridian/config.json"
}

run_seeded_host_model() {
  jq -n --argjson enum "$1" --argjson models "$2" --argjson ids "$3" \
    '{host_agent_enum: $enum, models: $models, agent_model_ids: $ids}' > "$TEST_ROOT/host-model.json"
  run jq -r -f "$REPO_ROOT/scripts/lib/seeded-host-model.jq" "$TEST_ROOT/host-model.json"
}

copy_plugin() {
  PLUGIN="$TEST_ROOT/plugin"
  mkdir -p "$PLUGIN/templates" "$PROJECT/.meridian"
  cp -R "$REPO_ROOT/scripts" "$PLUGIN/scripts"
  ln -s "$REPO_ROOT/config" "$PLUGIN/config"
  cp -R "$REPO_ROOT/templates/." "$PLUGIN/templates/"
}

write_routing_stub() {
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$1'" > "$PLUGIN/scripts/meridian-routing.sh"
}

run_plugin_preflight() {
  run bash "$PLUGIN/scripts/team-command-transaction.sh" preflight --project-root "$PROJECT" "$@"
}

expect_exact_output() {
  [ "$output" = "$2" ] || record_case_failure "$1" "output=[$output] want=[$2]"
}

expect_refused() {
  local label=$1 fragment=$2
  [ "$status" -ne 0 ] || record_case_failure "$label" "command succeeded output=$output"
  expect_output_has "$label" "$fragment"
}

preflight_turns_row() {
  local label="$1" engineer="$2" config="$3" defaults_filter="$4" want="$5"
  jq "$defaults_filter" "$REPO_ROOT/templates/agent-roles/defaults.json" > "$PLUGIN/templates/agent-roles/defaults.json"
  printf '%s\n' "$config" > "$PROJECT/.meridian/config.json"
  run_plugin_preflight --engineer "$engineer"
}

@test "seeded host model skips custom enum heads, prefers sonnet, maps claude selectors, and fails closed on custom ids" {
  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review","opus","sonnet"]' '[]' '{}'
  expect_case prefers-sonnet 0
  expect_exact_output prefers-sonnet sonnet

  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review","amber","violet"]' '[]' '{}'
  expect_case first-native-family 0
  expect_exact_output first-native-family amber

  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review"]' \
    '[{"selector":"claude-amber-route","label":"Amber Route","description":"Amber Route"}]' \
    '{"claude-amber-route":"amber"}'
  expect_case claude-selector-mapped 0
  expect_exact_output claude-selector-mapped amber

  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review"]' \
    '[{"selector":"leverframe:openai-oauth:codex-auto-review","label":"custom","description":"custom"}]' \
    '{"leverframe:openai-oauth:codex-auto-review":"leverframe:openai-oauth:codex-auto-review"}'
  expect_case_silent only-custom-ids 0

  assert_no_case_failures
}

resolve_preflight_routes_and_turn_budgets() {
  local binary="$TEST_ROOT/claude-seeded" label effort expected base engineer config defaults_filter want

  write_seeded_claude_fixture \
    "$binary" \
    '["haiku","sonnet","opus","leverframe:openai-oauth:codex-auto-review"]' \
    '[{id:"claude-haiku-route",family:"haiku",display_name:"Haiku Route"},{id:"claude-sonnet-5",family:"sonnet",display_name:"Sonnet 5"},{id:"claude-opus-5",family:"opus",display_name:"Opus 5"}]'
  run env CLAUDE_CODE_EXECPATH="$binary" bash "$TRANSACTION" preflight --project-root "$PROJECT"
  expect_case seeded-prefers-sonnet 0
  expect_jq_output seeded-prefers-sonnet '.routing.mode == "seeded" and .routing.model == "sonnet"'

  copy_plugin
  printf '%s\n' '{"routing":{"active_profile":"balanced"}}' > "$PROJECT/.meridian/config.json"
  write_routing_stub '{"model":"nova-route","profile":null,"reasoning":"deliberate","role":"web-engineer"}'
  run_plugin_preflight
  expect_case null-saved-profile 0
  expect_jq_output null-saved-profile '.routing.mode == "saved" and .routing.profile == "null"'

  write_routing_stub '{"model":"nova-route","profile":"balanced","reasoning":"deliberate","role":"web-engineer"}'
  base=$(jq -r '.["web-engineer"].maxTurns' "$REPO_ROOT/templates/agent-roles/defaults.json")
  while IFS='|' read -r label effort expected; do
    [ -n "$label" ] || continue
    jq -n --arg effort "$effort" '{routing: {active_profile: "balanced"}, effort: $effort}' \
      > "$PROJECT/.meridian/config.json"
    run_plugin_preflight
    expect_case "$label" 0
    [ "$(jq -r '.routing.max_turns' <<< "$output")" = "$(( (base * expected + 5) / 10 ))" ] \
      || record_case_failure "$label" "expected tenths=$expected of base=$base output=$output"
  done <<'CASES'
thorough|thorough|15
balanced|balanced|10
fast|fast|8
turbo|turbo|6
unknown-value-falls-back-to-balanced|reckless|10
CASES

  write_routing_stub '{"model":"nova-route","profile":"balanced","reasoning":"deliberate","role":"python-engineer"}'
  while IFS='@' read -r label engineer config defaults_filter want; do
    [ -n "$label" ] || continue
    preflight_turns_row "$label" "$engineer" "$config" "$defaults_filter" "$want"
    expect_case "$label" 0
    [ "$(jq -c '.routing.max_turns' <<< "$output")" = "$want" ] \
      || record_case_failure "$label" "want=$want output=$output"
  done <<'CASES'
agent-max-turns-is-absolute@python-engineer@{"routing":{"active_profile":"balanced"},"effort":"thorough","agent_max_turns":{"python-engineer":10}}@.@10
agent-max-turns-false-is-unlimited@python-engineer@{"routing":{"active_profile":"balanced"},"agent_max_turns":{"python-engineer":false}}@.@null
dev-alias-reaches-the-engineer@python-engineer@{"routing":{"active_profile":"balanced"},"agent_max_turns":{"dev":9}}@.@9
roles-max-turns-is-effort-scaled@python-engineer@{"routing":{"active_profile":"balanced"},"effort":"thorough","roles":{"python-engineer":{"max_turns":20}}}@.@30
roles-zero-is-unlimited@python-engineer@{"routing":{"active_profile":"balanced"},"effort":"thorough","roles":{"python-engineer":{"max_turns":0}}}@.@null
defaults-zero-is-unlimited@python-engineer@{"routing":{"active_profile":"balanced"}}@.["python-engineer"].maxTurns = 0@null
CASES

  preflight_turns_row invalid-agent-max-turns-names-its-key python-engineer \
    '{"routing":{"active_profile":"balanced"},"agent_max_turns":{"python-engineer":"abc"}}' . ''
  expect_refused invalid-agent-max-turns-names-its-key "invalid agent_max_turns.python-engineer value 'abc'"

  assert_no_case_failures
}

preflight_without_writes_and_reject_protected_scopes() {
  local expected_root label scope_args expected
  local -a scope_array

  run bash "$TRANSACTION" preflight --project-root "$PROJECT" --scope src
  expect_case read-only 0
  expected_root=$(cd -P "$PROJECT" && pwd -P)
  jq -e --arg root "$expected_root" '
    .project_root == $root
    and .side_effects == false
    and .team_mode == "pair"
  ' <<< "$output" >/dev/null || record_case_failure read-only "root, side effects or team mode differ output=$output"
  expect_no_path read-only-no-runfiles "$PROJECT/.temporary-agent-runfiles"

  while IFS='|' read -r label scope_args expected; do
    [ -n "$label" ] || continue
    scope_array=()
    [ -z "$scope_args" ] || read -r -a scope_array <<< "$scope_args"
    run bash "$TRANSACTION" preflight --project-root "$PROJECT" ${scope_array[@]+"${scope_array[@]}"}
    expect_case "$label" 0
    [ "$(jq -c '.scopes' <<< "$output")" = "$expected" ] \
      || record_case_failure "$label" "expected=$expected output=$output"
  done <<'CASES'
default-is-repository-root||["."]
repeated-scope-deduplicates|--scope src --scope src|["src"]
CASES

  mkdir -p "$PROJECT/.claude"
  run bash "$TRANSACTION" preflight --project-root "$PROJECT" --scope .claude
  expect_refused protected-scope "protected"
  expect_no_path protected-scope-no-runfiles "$PROJECT/.temporary-agent-runfiles"

  jq -n '{env:{CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:"1"}}' > "$PROJECT/.claude/settings.json"
  run env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
    bash "$TRANSACTION" preflight --project-root "$PROJECT"
  expect_case agent-teams-from-settings 0
  expect_jq_output agent-teams-from-settings '.agent_teams.enabled == true and .agent_teams.status.source == "settings"'

  assert_no_case_failures
}

prepare_pair_and_trio_contracts() {
  local contract_path manifest name

  prepare_run run-pair --scope src
  jq -e --argjson scopes '["src"]' '.ordered_actions == ["agent_spawn", "task_create"]
    and .schema_version == 3
    and .team_mode == "pair"
    and .scopes == $scopes
    and .requested_backend == "in_process"
    and .resolved_backend == "in_process"
    and (.teammates | length) == 2
    and .contract_state == "dispatched"' <<< "$output" >/dev/null \
    || record_case_failure pair-output "prepare output differs output=$output"
  expect_path pair-run-json "$RUN_ROOT/run.json"
  expect_path pair-diagnostics "$RUN_ROOT/diagnostics.jsonl"
  expect_jq pair-run-json "$RUN_ROOT/run.json" '.status == "planned"
    and .requested_backend == "in_process"
    and .resolved_backend == "in_process"
    and (.teammates | length) == 2'
  expect_jq pair-run-contract "$RUN_ROOT/contract.json" '.requested_backend == "in_process" and .resolved_backend == "in_process"'
  contract_path="$RUN_ROOT/contracts/tasks/$CONTRACT_ID.json"
  expect_path pair-contract "$contract_path"
  [ "$(find "$RUN_ROOT/contracts/tasks" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ] \
    || record_case_failure pair-contract "expected exactly one task contract"
  jq -e --arg id "$CONTRACT_ID" '
    .schema_version == 3
    and .contract_id == $id
    and .team_mode == "pair"
    and .roles == ["web-engineer", "web-code-critic"]
    and .runtime_kind == "native-team"
    and .communication_policy == "native-team"
    and .requested_backend == "in_process"
    and .resolved_backend == "in_process"
    and .state == "dispatched"
    and .capabilities_by_role["web-engineer"] == [{access:"write",kind:"directory",path:"src"}]
    and .capabilities_by_role["web-code-critic"] == []
  ' "$contract_path" >/dev/null || record_case_failure pair-contract "contract fields differ"
  manifest="$RUN_ROOT/agent-manifest.json"
  expect_path pair-manifest "$manifest"
  while IFS= read -r name; do
    jq -e --arg name "$name" --arg id "$CONTRACT_ID" '
      .agents[$name].contract_id == $id
      and .agents[$name].schema_version == 3
      and .agents[$name].runtime_kind == "native-team"
      and .agents[$name].state == "registered"
    ' "$manifest" >/dev/null || record_case_failure "pair-teammate-$name" "manifest entry differs"
    expect_path "pair-definition-$name" "$PROJECT/.claude/agents/$name.md"
  done < <(jq -r '.teammates[].name' <<< "$output")

  prepare_run run-trio --scope src --test-dev
  expect_jq_output trio-output '.team_mode == "trio" and (.teammates | length) == 3'
  expect_jq trio-contract "$RUN_ROOT/contracts/tasks/$CONTRACT_ID.json" '
    .team_mode == "trio"
    and .roles == ["web-engineer", "web-code-critic", "test-dev"]
    and .test_dev == true
    and .capabilities_by_role["test-dev"] == []
  '

  seed_saved_routing_root
  prepare_run run-init --scope src
  expect_jq_output init-output '.control_root_kind == "active-planning" and (.run_root | length) > 0'
  expect_path init-run-json "$RUN_ROOT/run.json"
  expect_path init-run-contract "$RUN_ROOT/contract.json"
  expect_path init-diagnostics "$RUN_ROOT/diagnostics.jsonl"
  expect_path init-manifest "$PROJECT/.meridian/.agent-manifest.json"
  expect_path init-task-contract "$PROJECT/.meridian/.contracts/tasks/$CONTRACT_ID.json"

  assert_no_case_failures
}

emit_backend_spawn_payloads_and_block_contract_drift() {
  local backend name

  prepare_run run-spawn --scope src
  run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  expect_case payload-shape 0
  expect_jq_output payload-shape '
    (.agent_payloads | length) == 2
    and all(.agent_payloads[]; (keys | sort) == ["name", "subagent_type"])
    and (.next_action == "task-payload")
  '
  expect_jq_output payload-roster '[.agent_payloads[].subagent_type] == .roster'

  for backend in tmux workflow; do
    prepare_run "run-$backend" --scope src
    retarget_run_backend "$backend"
    run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
    expect_case "backend-$backend" 0
    [ "$(jq '.agent_payloads | length' <<< "$output")" -eq 2 ] \
      || record_case_failure "backend-$backend" "expected two payloads output=$output"
  done

  prepare_run run-backend-drift --scope src
  rewrite_json "$RUN_ROOT/run.json" '.resolved_backend = "tmux"'
  run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  expect_refused backend-sidecar-drift "backend metadata does not match the contract"

  prepare_run run-spawn-guard --scope src
  name=$(jq -r '.teammates[0].name' "$RUN_ROOT/run.json")
  rewrite_json "$RUN_ROOT/agent-manifest.json" --arg name "$name" '.agents[$name].contract_id = "tampered"'
  run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  expect_refused manifest-identity-drift "manifest backend metadata does not match the contract"

  assert_no_case_failures
}

gate_task_steps_on_teammate_evidence() {
  local name first second

  prepare_run run-record --scope src
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "meridian-ghost"
  expect_refused record-spawn-unknown "not registered"
  name=$(jq -r '.teammates[0].name' "$RUN_ROOT/run.json")
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$name"
  expect_refused record-spawn-unclaimed "not running"
  manifest_set_running
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$name"
  expect_case record-spawn-running 0
  expect_jq_output record-spawn-running '.recorded == true and .spawn_complete == false'

  prepare_run run-gate --scope src
  manifest_set_running
  run bash "$TRANSACTION" task-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  expect_refused task-payload-no-spawns "spawn evidence is missing"
  first=$(jq -r '.teammates[0].name' "$RUN_ROOT/run.json")
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$first"
  expect_case task-payload-first-spawn 0
  run bash "$TRANSACTION" task-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  expect_refused task-payload-one-spawn "spawn evidence is missing"
  second=$(jq -r '.teammates[1].name' "$RUN_ROOT/run.json")
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$second"
  expect_case task-payload-second-spawn 0
  expect_jq_output task-payload-second-spawn '.spawn_complete == true'
  run bash "$TRANSACTION" task-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  expect_case task-payload-ready 0
  jq -e --arg id "$CONTRACT_ID" '.task.subject == $id and .task.description == $id' <<< "$output" >/dev/null \
    || record_case_failure task-payload-ready "task subject or description differs output=$output"

  prepare_run run-task --scope src
  manifest_set_running
  record_full_roster
  run bash "$TRANSACTION" record-task --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --task-id task-1
  expect_refused record-task-unbound "not bound"
  manifest_bind_task task-1
  run bash "$TRANSACTION" record-task --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --task-id task-1
  expect_case record-task-bound 0
  expect_jq_output record-task-bound '.recorded == true'
  expect_jq record-task-bound-run "$RUN_ROOT/run.json" '.records["task:task-1"].status == "bound"'

  assert_no_case_failures
}

retain_terminal_runfiles_and_report_summary() {
  prepare_run run-fail --scope src
  run bash "$TRANSACTION" fail --project-root "$PROJECT" --run-root "$RUN_ROOT" --event "spawn rejected"
  expect_case fail 0
  expect_jq_output fail '.status == "failed"'
  expect_path fail-run-json "$RUN_ROOT/run.json"
  expect_jq fail-run-json "$RUN_ROOT/run.json" '.status == "failed"'
  expect_file_line fail-diagnostics "$RUN_ROOT/diagnostics.jsonl" 'spawn rejected'

  prepare_run run-summary --scope src
  run bash "$TRANSACTION" complete --project-root "$PROJECT" --run-root "$RUN_ROOT" --event "done"
  expect_case complete 0
  run bash "$TRANSACTION" summary --project-root "$PROJECT" --run-root "$RUN_ROOT"
  expect_case summary 0 "run_id: run-summary"
  expect_output_has summary "status: completed"
  expect_output_has summary "$CONTRACT_ID=dispatched"

  assert_no_case_failures
}

roster_rows() {
  local label roles expected_status expected_count team role args HOME
  export HOME="$TEST_ROOT/home"
  mkdir -p "$HOME"
  cd "$PROJECT" || return 1
  while IFS='|' read -r label roles expected_status expected_count team; do
    args=()
    for role in $roles; do args+=(--role "$role"); done
    run bash "$TRANSACTION" propose --project-root "$PROJECT" "${args[@]}"
    expect_case "$label" "$expected_status"
    if [ "$expected_status" -eq 0 ]; then
      expect_jq_output "$label" ".team_mode == \"$team\" and (.roles | length) == $expected_count and (.roles | unique | length) == $expected_count"
    fi
  done
  assert_no_case_failures
}

infer_pair_and_trio_rosters() {
  roster_rows <<'CASES'
inferred-critic|python-engineer|0|2|pair
explicit-critic|python-critic python-engineer|0|2|pair
trio|test-dev python-critic python-engineer|0|3|trio
CASES
}

@test "team transactions validate rosters and enforce the dispatch lifecycle" {
  run_scenario_cases resolve_preflight_routes_and_turn_budgets \
    preflight_without_writes_and_reject_protected_scopes prepare_pair_and_trio_contracts \
    emit_backend_spawn_payloads_and_block_contract_drift gate_task_steps_on_teammate_evidence \
    retain_terminal_runfiles_and_report_summary infer_pair_and_trio_rosters reject_invalid_rosters
}

reject_invalid_rosters() {
  roster_rows <<'CASES'
unknown|not-a-role|1|0|
duplicate-test|python-engineer test-dev test-dev|1|0|
two-critics|python-engineer python-critic web-code-critic|1|0|
two-engineers|python-engineer web-engineer|1|0|
missing-engineer|python-critic test-dev|1|0|
wrong-critic|python-engineer web-code-critic|1|0|
unpaired-role|scout|1|0|
unpaired-explicit|scout python-critic|1|0|
CASES
}
