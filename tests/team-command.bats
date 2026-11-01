#!/usr/bin/env bats

load test_helper

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  TRANSACTION="$REPO_ROOT/scripts/team-command-transaction.sh"
  TEST_ROOT="$(mktemp -d)"
  SETTINGS="$TEST_ROOT/settings.json"
  printf '%s\n' '{}' > "$SETTINGS"
  PROJECT="$TEST_ROOT/project"
  mkdir -p "$PROJECT/src" "$TEST_ROOT/claude"
  (cd "$PROJECT" && git init -q)
  export LBWC_SETTINGS_PATH="$SETTINGS"
  export CLAUDE_CONFIG_DIR="$TEST_ROOT/claude"
  unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS || true
  use_claude_fixture "$TEST_ROOT/host-claude"
}

teardown() {
  rm -rf "$TEST_ROOT" 2>/dev/null || { sleep 1; rm -rf "$TEST_ROOT" 2>/dev/null || true; }
}

prepare_run() {
  local run_id="$1"
  shift
  RUN_ID="$run_id"
  LBWC_SETTINGS_PATH="$SETTINGS" run bash "$TRANSACTION" prepare \
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
  mkdir -p "$PROJECT/.lbwc-planning"
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
  ' > "$PROJECT/.lbwc-planning/claude-capabilities.json"
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
  ' "$REPO_ROOT/config/settings.json" > "$PROJECT/.lbwc-planning/config.json"
}

run_seeded_host_model() {
  jq -n --argjson enum "$1" --argjson models "$2" --argjson ids "$3" \
    '{host_agent_enum: $enum, models: $models, agent_model_ids: $ids}' > "$TEST_ROOT/host-model.json"
  run jq -r -f "$REPO_ROOT/scripts/lib/seeded-host-model.jq" "$TEST_ROOT/host-model.json"
}

@test "seeded host model skips a custom enum head and prefers sonnet when present" {
  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review","opus","sonnet"]' '[]' '{}'

  [ "$status" -eq 0 ]
  [ "$output" = "sonnet" ]
}

@test "seeded host model uses the first native family when sonnet is absent" {
  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review","amber","violet"]' '[]' '{}'

  [ "$status" -eq 0 ]
  [ "$output" = "amber" ]
}

@test "seeded host model maps a claude selector when the enum is only custom ids" {
  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review"]' \
    '[{"selector":"claude-amber-route","label":"Amber Route","description":"Amber Route"}]' \
    '{"claude-amber-route":"amber"}'

  [ "$status" -eq 0 ]
  [ "$output" = "amber" ]
}

@test "seeded host model fails closed when only custom ids exist" {
  run_seeded_host_model '["leverframe:openai-oauth:codex-auto-review"]' \
    '[{"selector":"leverframe:openai-oauth:codex-auto-review","label":"custom","description":"custom"}]' \
    '{"leverframe:openai-oauth:codex-auto-review":"leverframe:openai-oauth:codex-auto-review"}'

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "preflight reports agent teams enabled from project settings" {
  mkdir -p "$PROJECT/.claude"
  jq -n '{env:{CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:"1"}}' \
    > "$PROJECT/.claude/settings.json"

  run env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
    bash "$TRANSACTION" preflight --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  jq -e '.agent_teams.enabled == true and .agent_teams.status.source == "settings"' \
    <<< "$output" >/dev/null
}

@test "preflight seeded routing prefers sonnet over enum order" {
  local binary="$TEST_ROOT/claude-seeded"
  write_seeded_claude_fixture \
    "$binary" \
    '["haiku","sonnet","opus","leverframe:openai-oauth:codex-auto-review"]' \
    '[{id:"claude-haiku-route",family:"haiku",display_name:"Haiku Route"},{id:"claude-sonnet-5",family:"sonnet",display_name:"Sonnet 5"},{id:"claude-opus-5",family:"opus",display_name:"Opus 5"}]'

  run env CLAUDE_CODE_EXECPATH="$binary" \
    bash "$TRANSACTION" preflight --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  jq -e '.routing.mode == "seeded" and .routing.model == "sonnet"' <<< "$output" >/dev/null
}

@test "preflight reports the string null for a null saved-route profile" {
  local plugin="$TEST_ROOT/plugin"
  mkdir -p "$plugin" "$PROJECT/.lbwc-planning"
  cp -R "$REPO_ROOT/scripts" "$plugin/scripts"
  ln -s "$REPO_ROOT/config" "$plugin/config"
  ln -s "$REPO_ROOT/templates" "$plugin/templates"
  printf '%s\n' '{"routing":{"active_profile":"balanced"}}' > "$PROJECT/.lbwc-planning/config.json"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' '{\"model\":\"nova-route\",\"profile\":null,\"reasoning\":\"deliberate\",\"role\":\"web-engineer\"}'" \
    > "$plugin/scripts/lbwc-routing.sh"

  run bash "$plugin/scripts/team-command-transaction.sh" preflight --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  jq -e '.routing.mode == "saved" and .routing.profile == "null"' <<< "$output" >/dev/null
}

@test "preflight is read-only and reports the canonical root, pair mode, and no side effects" {
  run bash "$TRANSACTION" preflight --project-root "$PROJECT" --scope src

  [ "$status" -eq 0 ]
  expected_root=$(cd -P "$PROJECT" && pwd -P)
  jq -e --arg root "$expected_root" '
    .project_root == $root
    and .side_effects == false
    and .team_mode == "pair"
  ' <<< "$output" >/dev/null
  [ ! -e "$PROJECT/.temporary-agent-runfiles" ]
}

@test "preflight resolves scope arguments to a canonical deduplicated list" {
  local label scope_args expected
  local -a scope_array
  while IFS='|' read -r label scope_args expected; do
    [ -n "$label" ] || continue
    scope_array=()
    [ -z "$scope_args" ] || read -r -a scope_array <<< "$scope_args"
    run bash "$TRANSACTION" preflight --project-root "$PROJECT" ${scope_array[@]+"${scope_array[@]}"}
    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [ "$(jq -c '.scopes' <<< "$output")" = "$expected" ] \
      || { echo "case=$label expected=$expected output=$output" >&2; return 1; }
  done <<'CASES'
default-is-repository-root||["."]
repeated-scope-deduplicates|--scope src --scope src|["src"]
CASES
}

@test "preflight rejects a protected scope" {
  mkdir -p "$PROJECT/.claude"
  run bash "$TRANSACTION" preflight --project-root "$PROJECT" --scope .claude

  [ "$status" -ne 0 ]
  [[ "$output" == *"protected"* ]]
  [ ! -e "$PROJECT/.temporary-agent-runfiles" ]
}

@test "prepare creates a run root, one dispatched pair contract, and generated definitions" {
  prepare_run run-pair --scope src

  jq -e --argjson scopes '["src"]' '.ordered_actions == ["agent_spawn", "task_create"]
    and .schema_version == 3
    and .team_mode == "pair"
    and .scopes == $scopes
    and .requested_backend == "in_process"
    and .resolved_backend == "in_process"
    and (.teammates | length) == 2
    and .contract_state == "dispatched"' <<< "$output" >/dev/null
  [ -f "$RUN_ROOT/run.json" ]
  [ -f "$RUN_ROOT/diagnostics.jsonl" ]
  jq -e '.status == "planned"
    and .requested_backend == "in_process"
    and .resolved_backend == "in_process"
    and (.teammates | length) == 2' "$RUN_ROOT/run.json" >/dev/null
  jq -e '.requested_backend == "in_process" and .resolved_backend == "in_process"' \
    "$RUN_ROOT/contract.json" >/dev/null
  contract_path="$RUN_ROOT/contracts/tasks/$CONTRACT_ID.json"
  [ -f "$contract_path" ]
  [ "$(find "$RUN_ROOT/contracts/tasks" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
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
  ' "$contract_path" >/dev/null
  manifest="$RUN_ROOT/agent-manifest.json"
  [ -f "$manifest" ]
  while IFS= read -r name; do
    jq -e --arg name "$name" --arg id "$CONTRACT_ID" '
      .agents[$name].contract_id == $id
      and .agents[$name].schema_version == 3
      and .agents[$name].runtime_kind == "native-team"
      and .agents[$name].state == "registered"
    ' "$manifest" >/dev/null
    [ -f "$PROJECT/.claude/agents/$name.md" ]
  done < <(jq -r '.teammates[].name' <<< "$output")
}

@test "prepare with --test-dev issues a trio contract and registers three teammates" {
  prepare_run run-trio --scope src --test-dev

  jq -e '.team_mode == "trio" and (.teammates | length) == 3' <<< "$output" >/dev/null
  contract_path="$RUN_ROOT/contracts/tasks/$CONTRACT_ID.json"
  jq -e '
    .team_mode == "trio"
    and .roles == ["web-engineer", "web-code-critic", "test-dev"]
    and .test_dev == true
    and .capabilities_by_role["test-dev"] == []
  ' "$contract_path" >/dev/null
}

@test "prepare keeps an initialized project control root while always creating a run root" {
  seed_saved_routing_root

  prepare_run run-init --scope src

  jq -e '.control_root_kind == "active-planning" and (.run_root | length) > 0' <<< "$output" >/dev/null
  [ -f "$RUN_ROOT/run.json" ]
  [ -f "$RUN_ROOT/contract.json" ]
  [ -f "$RUN_ROOT/diagnostics.jsonl" ]
  [ -f "$PROJECT/.lbwc-planning/.agent-manifest.json" ]
  [ -f "$PROJECT/.lbwc-planning/.contracts/tasks/$CONTRACT_ID.json" ]
}

@test "spawn-payload accepts a run whose contract uses a tmux or workflow backend" {
  local backend
  for backend in tmux workflow; do
    prepare_run "run-$backend" --scope src
    retarget_run_backend "$backend"

    run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"

    [ "$status" -eq 0 ] || { echo "backend=$backend status=$status output=$output" >&2; return 1; }
    [ "$(jq '.agent_payloads | length' <<< "$output")" -eq 2 ] \
      || { echo "backend=$backend output=$output" >&2; return 1; }
  done
}

@test "spawn-payload emits Agent calls with only subagent_type and name" {
  prepare_run run-spawn --scope src

  run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"

  [ "$status" -eq 0 ]
  jq -e '
    (.agent_payloads | length) == 2
    and all(.agent_payloads[]; (keys | sort) == ["name", "subagent_type"])
    and (.next_action == "task-payload")
  ' <<< "$output" >/dev/null
  jq -e '[.agent_payloads[].subagent_type] == .roster' <<< "$output" >/dev/null
}

@test "spawn-payload rejects backend sidecar drift from the contract" {
  prepare_run run-backend-drift --scope src
  rewrite_json "$RUN_ROOT/run.json" '.resolved_backend = "tmux"'

  run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"backend metadata does not match the contract"* ]]
}

@test "spawn-payload blocks a teammate whose manifest identity does not match the contract" {
  prepare_run run-spawn-guard --scope src
  name=$(jq -r '.teammates[0].name' "$RUN_ROOT/run.json")
  rewrite_json "$RUN_ROOT/agent-manifest.json" --arg name "$name" '.agents[$name].contract_id = "tampered"'

  run bash "$TRANSACTION" spawn-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"manifest backend metadata does not match the contract"* ]]
}

@test "record-spawn tracks the roster and blocks unknown or unclaimed teammates" {
  prepare_run run-record --scope src

  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "lbwc-ghost"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not registered"* ]]

  name=$(jq -r '.teammates[0].name' "$RUN_ROOT/run.json")
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not running"* ]]

  manifest_set_running
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$name"
  [ "$status" -eq 0 ]
  jq -e '.recorded == true and .spawn_complete == false' <<< "$output" >/dev/null
}

@test "task-payload blocks until every roster teammate has recorded spawn evidence" {
  prepare_run run-gate --scope src
  manifest_set_running

  run bash "$TRANSACTION" task-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spawn evidence is missing"* ]]

  first=$(jq -r '.teammates[0].name' "$RUN_ROOT/run.json")
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$first"
  [ "$status" -eq 0 ]

  run bash "$TRANSACTION" task-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spawn evidence is missing"* ]]

  second=$(jq -r '.teammates[1].name' "$RUN_ROOT/run.json")
  run bash "$TRANSACTION" record-spawn --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --teammate "$second"
  [ "$status" -eq 0 ]
  jq -e '.spawn_complete == true' <<< "$output" >/dev/null

  run bash "$TRANSACTION" task-payload --project-root "$PROJECT" --run-root "$RUN_ROOT"
  [ "$status" -eq 0 ]
  jq -e --arg id "$CONTRACT_ID" '.task.subject == $id and .task.description == $id' <<< "$output" >/dev/null
}

@test "record-task binds the contract-bound native task after spawns" {
  prepare_run run-task --scope src
  manifest_set_running
  record_full_roster

  run bash "$TRANSACTION" record-task --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --task-id task-1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not bound"* ]]

  manifest_bind_task task-1
  run bash "$TRANSACTION" record-task --project-root "$PROJECT" --run-root "$RUN_ROOT" \
    --contract-id "$CONTRACT_ID" --task-id task-1
  [ "$status" -eq 0 ]
  jq -e '.recorded == true' <<< "$output" >/dev/null
  jq -e '.records["task:task-1"].status == "bound"' "$RUN_ROOT/run.json" >/dev/null
}

@test "fail retains runfiles and appends diagnostics" {
  prepare_run run-fail --scope src

  run bash "$TRANSACTION" fail --project-root "$PROJECT" --run-root "$RUN_ROOT" --event "spawn rejected"
  [ "$status" -eq 0 ]
  jq -e '.status == "failed"' <<< "$output" >/dev/null
  [ -f "$RUN_ROOT/run.json" ]
  jq -e '.status == "failed"' "$RUN_ROOT/run.json" >/dev/null
  grep -F 'spawn rejected' "$RUN_ROOT/diagnostics.jsonl" >/dev/null
}

@test "summary reports terminal status and records" {
  prepare_run run-summary --scope src
  run bash "$TRANSACTION" complete --project-root "$PROJECT" --run-root "$RUN_ROOT" --event "done"
  [ "$status" -eq 0 ]

  run bash "$TRANSACTION" summary --project-root "$PROJECT" --run-root "$RUN_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run_id: run-summary"* ]]
  [[ "$output" == *"status: completed"* ]]
  [[ "$output" == *"$CONTRACT_ID=dispatched"* ]]
}
