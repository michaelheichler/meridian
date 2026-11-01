#!/usr/bin/env bats

load test_helper

GENERATOR="${SCRIPTS_DIR}/agent-generator.sh"
export GENERATOR

setup() {
  TEST_TEMP_DIR=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lbwc-generator.XXXXXX")" && pwd -P)
  export TEST_TEMP_DIR
  export _ORIG_HOME="${HOME:-}"
  export _ORIG_LBWC_PLANNING_DIR="${LBWC_PLANNING_DIR:-}"
  export HOME="$TEST_TEMP_DIR"
  unset LBWC_PLANNING_DIR CLAUDE_SESSION_ID 2>/dev/null || true
  mkdir -p "$TEST_TEMP_DIR/.lbwc-planning"
  ROUTE_BINARY="$TEST_TEMP_DIR/claude-generator-fixture"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "fixture"' > "$ROUTE_BINARY"
  chmod +x "$ROUTE_BINARY"
  ROUTE_SHA=$(shasum -a 256 "$ROUTE_BINARY" | awk '{print $1}')
  jq -n --arg binary "$ROUTE_BINARY" --arg sha "$ROUTE_SHA" '
    {
      schema_version: 1,
      source: {binary_path: $binary, version: "fixture", sha256: $sha, detected_at: "2035-01-02T03:04:05Z"},
      models: [
        {selector: "nova-route", label: "Nova Route", description: "Fixture selector"},
        {selector: "ember-path", label: "Ember Path", description: "Second fixture selector"}
      ],
      reasoning: {
        scope: "global",
        accepted_values: ["deliberate", "swift"],
        model_associations: {"nova-route": ["deliberate"]}
      }
    }
  ' > "$TEST_TEMP_DIR/.lbwc-planning/claude-capabilities.json"
  jq --slurpfile defaults "$PROJECT_ROOT/templates/agent-roles/defaults.json" '
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
  ' "$CONFIG_DIR/settings.json" > "$TEST_TEMP_DIR/.lbwc-planning/config.json"
  CONTRACT_SEQUENCE=0
}

teardown() {
  teardown_temp_dir
}

generate() {
  local -a arguments=("$@") contract_args=()
  local mode=solo role job="" index=0 value contract task_id
  if [ "${arguments[0]:-}" = "--pair" ]; then mode=pair; index=1; fi
  if [ "${arguments[0]:-}" = "--trio" ]; then mode=trio; index=1; fi
  role="${arguments[$index]:-}"
  if [[ " ${arguments[*]} " != *" --contract "* ]] && jq -e --arg role "${role#lbwc-}" 'has($role)' "$PROJECT_ROOT/templates/agent-roles/defaults.json" >/dev/null 2>&1; then
    index=$((index + 1))
    while [ "$index" -lt "${#arguments[@]}" ]; do
      value=${arguments[$index]}
      case "$value" in
        --job) index=$((index + 1)); job=${arguments[$index]} ;;
        --job=*) job=${value#*=} ;;
        --write-allowance|--role-write-allowance)
          index=$((index + 1)); contract_args+=("$value" "${arguments[$index]}") ;;
        --write-allowance=*|--role-write-allowance=*)
          contract_args+=("${value%%=*}" "${value#*=}") ;;
      esac
      index=$((index + 1))
    done
    if [ -n "$job" ]; then
      CONTRACT_SEQUENCE=$((CONTRACT_SEQUENCE + 1))
      task_id="test-${BATS_TEST_NUMBER:-0}-${CONTRACT_SEQUENCE}"
      contract=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$task_id" \
        --command test --role "${role#lbwc-}" --team "$mode" --job "$job" "${contract_args[@]}")
      arguments+=(--contract "$contract" --task-id "$(basename "$contract" .json)")
    fi
  fi
  run bash -c 'cd "$TEST_TEMP_DIR" && exec bash "$GENERATOR" "$@"' _ "${arguments[@]}"
}

make_contract() {
  local role="$1" task="$2" allowances="$3" team="${4:-solo}" job="${5:-contract task}" path item
  local -a args=()
  while IFS= read -r item; do
    [ -n "$item" ] && args+=(--write-allowance "$item")
  done < <(jq -r '.[]' <<< "$allowances")
  path=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$task" \
    --command test --role "$role" --team "$team" --job "$job" "${args[@]}")
  printf '%s' "$path"
}

generate_raw() {
  run bash -c 'cd "$TEST_TEMP_DIR" && exec bash "$GENERATOR" "$@"' _ "$@"
}

manifest_path() {
  printf '%s' "$TEST_TEMP_DIR/.lbwc-planning/.agent-manifest.json"
}

generated_name() {
  printf '%s\n' "$output" | grep -o "lbwc-$1-[a-z0-9-]*" | head -1
}

agent_file_count() {
  find "$TEST_TEMP_DIR/.claude/agents" -type f 2>/dev/null | wc -l | tr -d ' '
}

reset_generated_state() {
  rm -rf "$TEST_TEMP_DIR/.claude" "$(manifest_path)"
}

assert_rejected_without_mutation() {
  local label="$1" expected="$2"
  [ "$status" -eq 1 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
  [[ "$output" =~ $expected ]] || { echo "case=$label expected=$expected output=$output" >&2; return 1; }
  [ ! -f "$(manifest_path)" ] || { echo "case=$label manifest was created" >&2; return 1; }
  [ "$(agent_file_count)" -eq 0 ] || { echo "case=$label agent file was rendered" >&2; return 1; }
}

issue_schema3() {
  local id="$1" job="$2" capability="$3"
  shift 3
  S3_ID="$id"
  S3_JOB="$job"
  S3_CAPABILITY="$capability"
  S3_ROOT="$TEST_TEMP_DIR/.temporary-agent-runfiles/runs/$id"
  mkdir -p "$S3_ROOT"
  S3_CONTRACT=$(bash "$SCRIPTS_DIR/task-contract.sh" issue "$TEST_TEMP_DIR" "$id" \
    --command team --role web-engineer --team solo --job "$job" \
    --control-root "$S3_ROOT" --write-capability "$capability" "$@")
  S3_ROOT=$(cd -P "$S3_ROOT" && pwd -P)
}

schema3_arguments() {
  S3_ARGUMENTS=(--job "$S3_JOB" --task-id "$(basename "$S3_CONTRACT" .json)"
    --contract "$S3_CONTRACT" --control-root "$S3_ROOT" --write-capability "$S3_CAPABILITY")
}

generate_schema3() {
  schema3_arguments
  generate web-engineer "${S3_ARGUMENTS[@]}" "$@"
}

generate_native_team() {
  schema3_arguments
  run bash "$SCRIPTS_DIR/agent-generator.sh" --native-team web-engineer "${S3_ARGUMENTS[@]}" "$@"
}

seed_solo_agent() {
  local state="$1" name
  generate docs --job "seed the solo agent"
  [ "$status" -eq 0 ] || { echo "seed generation failed: $output" >&2; return 1; }
  name=$(jq -r '.agents | keys[0]' "$(manifest_path)")
  jq --arg name "$name" --arg state "$state" '.agents[$name].state = $state' "$(manifest_path)" > "$(manifest_path).tmp"
  mv "$(manifest_path).tmp" "$(manifest_path)"
}

assert_exclusive_blocked() {
  local label="$1" expected="$2"
  [ "$status" -eq 1 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
  [[ "$output" == *"$expected"* ]] || { echo "case=$label expected=$expected output=$output" >&2; return 1; }
  [ "$(jq '.agents | length' "$(manifest_path)")" -eq 1 ] || { echo "case=$label manifest gained an agent" >&2; return 1; }
  [ "$(agent_file_count)" -eq 1 ] || { echo "case=$label agent file count changed" >&2; return 1; }
}

assert_exclusive_admitted() {
  local label="$1" state="$2" same registered
  [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
  same=$(jq --arg state "$state" '[.agents[] | select(.state == $state)] | length' "$(manifest_path)")
  registered=$(jq '[.agents[] | select(.state == "registered")] | length' "$(manifest_path)")
  [ "$same" -eq 1 ] || { echo "case=$label $state agents=$same output=$output" >&2; return 1; }
  [ "$registered" -eq 2 ] || { echo "case=$label registered agents=$registered output=$output" >&2; return 1; }
}

@test "generator rejects bad arguments before any mutation" {
  local label runner expected arguments
  local -a words
  while IFS='@' read -r label runner expected arguments; do
    [ -n "$label" ] || continue
    reset_generated_state
    read -ra words <<< "$arguments"
    "$runner" "${words[@]}"
    assert_rejected_without_mutation "$label" "$expected"
  done <<'CASES'
no-args@generate@Usage: agent-generator.sh@
unknown-role@generate@invalid role@not-a-role --job do-something
missing-job@generate@--job is required@docs
no-contract@generate_raw@--contract is required@docs --job write-a-readme
missing-contract-file@generate@contract not found@python-engineer --job contract-task --task-id task-1 --contract missing.json --write-allowance src/a.py
CASES
}

@test "generated agents are rendered, registered, and named from the random source" {
  local label seed name
  while IFS='@' read -r label seed; do
    [ -n "$label" ] || continue
    reset_generated_state
    LBWC_AGENT_RANDOM_SEED="$seed" generate docs --job "write a README"
    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    name=$(generated_name docs)
    [[ "$output" == *"SPAWN_READY $name"* ]] || { echo "case=$label output=$output" >&2; return 1; }
    [[ "$name" =~ ^lbwc-docs-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$ ]] || { echo "case=$label name=$name" >&2; return 1; }
    [ -f "$TEST_TEMP_DIR/.claude/agents/$name.md" ] || { echo "case=$label definition missing for $name" >&2; return 1; }
    jq -e --arg name "$name" '.agents | has($name)' "$(manifest_path)" >/dev/null \
      || { echo "case=$label manifest lacks $name" >&2; return 1; }
  done <<'CASES'
unseeded@
seeded@42
CASES
}

@test "LBWC_AGENT_RANDOM_SEED yields a deterministic name across runs" {
  LBWC_AGENT_RANDOM_SEED=42 generate docs --job "first"
  [ "$status" -eq 0 ]
  local first
  first=$(generated_name docs)
  [ -n "$first" ]

  reset_generated_state
  LBWC_AGENT_RANDOM_SEED=42 generate docs --job "second"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SPAWN_READY $first"* ]]
}

generate_with_question_override() {
  case "$1" in
    empty) generate docs --job "write a README" --disallowed-tools "" --initial-prompt "" ;;
    partial) generate docs --job "write a README" --initial-prompt "Return user_decision_required." ;;
  esac
}

@test "question overrides keep the denial and the structured handoff" {
  local label override pattern name
  while IFS='@' read -r label override pattern; do
    [ -n "$label" ] || continue
    reset_generated_state
    generate_with_question_override "$override"
    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    name=$(generated_name docs)
    grep -qE -- "$pattern" "$TEST_TEMP_DIR/.claude/agents/$name.md" \
      || { echo "case=$label missing=$pattern" >&2; cat "$TEST_TEMP_DIR/.claude/agents/$name.md" >&2; return 1; }
  done <<'CASES'
empty-denial@empty@^disallowedTools: "AskUserQuestion"$
empty-handoff@empty@user_decision_required
partial-handoff-contract@partial@\\"type\\":\\"user_decision_required\\",\\"question\\":\\"clear user question\\",\\"response_shape\\":\\"bounded choices or freeform\\"
CASES
}

@test "pending decision rejects direct transitions without creating runtime state" {
  run bash -c 'bash "$1" create "$2" session-1 && bash "$1" record-bounded "$2" session-1 Fast' \
    _ "$SCRIPTS_DIR/pending-decision.sh" "$TEST_TEMP_DIR/.lbwc-planning"
  [ "$status" -eq 2 ]
  [[ "$output" == *"direct decision transitions are disabled"* ]]
  [ ! -e "$TEST_TEMP_DIR/.lbwc-planning/.runtime" ]
}

@test "generated agents preserve the saved selector and reasoning" {
  jq '
    .routing.profiles.balanced.roles.architect
    = {model: "ember-path", reasoning: "swift", status: "resolved"}
  ' "$TEST_TEMP_DIR/.lbwc-planning/config.json" > "$TEST_TEMP_DIR/.lbwc-planning/config.next"
  mv "$TEST_TEMP_DIR/.lbwc-planning/config.next" "$TEST_TEMP_DIR/.lbwc-planning/config.json"

  generate architect --job "build a roadmap"
  [ "$status" -eq 0 ]
  local name
  name=$(generated_name architect)
  [ -n "$name" ]
  jq -e --arg name "$name" '.agents[$name].model == "ember-path" and .agents[$name].effort == "swift"' \
    "$(manifest_path)" >/dev/null
  grep -F 'model: "ember-path"' "$TEST_TEMP_DIR/.claude/agents/$name.md" >/dev/null
  grep -F 'effort: "swift"' "$TEST_TEMP_DIR/.claude/agents/$name.md" >/dev/null
}

@test "generated agents omit default reasoning" {
  jq '.routing.profiles.balanced.roles.docs.reasoning = null' \
    "$TEST_TEMP_DIR/.lbwc-planning/config.json" > "$TEST_TEMP_DIR/.lbwc-planning/config.next"
  mv "$TEST_TEMP_DIR/.lbwc-planning/config.next" "$TEST_TEMP_DIR/.lbwc-planning/config.json"

  generate docs --job "write a README"
  [ "$status" -eq 0 ]
  local name
  name=$(generated_name docs)
  [ -n "$name" ]
  run grep -c '^effort:' "$TEST_TEMP_DIR/.claude/agents/$name.md"
  [ "$output" = "0" ]
  jq -e --arg name "$name" '.agents[$name].effort == null' "$(manifest_path)" >/dev/null
}

@test "generator blocks when the saved binary fingerprint is stale" {
  printf '%s\n' 'changed' >> "$ROUTE_BINARY"

  generate docs --job "write a README"

  [ "$status" -ne 0 ]
  [[ "$output" == *"fingerprint differs"* ]]
  [ ! -d "$TEST_TEMP_DIR/.claude/agents" ]
}

@test "generation uses saved routes when legacy model catalogs are absent" {
  local isolated="$TEST_TEMP_DIR/plugin"
  mkdir -p "$isolated"
  cp -R "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/templates" "$PROJECT_ROOT/config" "$isolated/"
  GENERATOR="$isolated/scripts/agent-generator.sh"
  export GENERATOR

  generate docs --job "write from saved routing authority"

  [ "$status" -eq 0 ]
  local name
  name=$(generated_name docs)
  [ -n "$name" ]
  grep -F 'model: "nova-route"' "$TEST_TEMP_DIR/.claude/agents/$name.md" >/dev/null
  grep -F 'effort: "deliberate"' "$TEST_TEMP_DIR/.claude/agents/$name.md" >/dev/null
}

@test "task write allowance is registered as an exact repository path" {
  generate python-engineer --job "repair the failing hook" --write-allowance hooks/skill_gate.py
  [ "$status" -eq 0 ]
  local name project_root
  name=$(generated_name python-engineer)
  project_root=$(cd "$TEST_TEMP_DIR" && pwd -P)
  [ -n "$name" ]
  jq -e --arg name "$name" --arg root "$project_root" '
    .agents[$name].project_root == $root
    and .agents[$name].write_allowances == ["hooks/skill_gate.py"]
  ' "$(manifest_path)" >/dev/null
}

@test "schema 3 generation records contract-derived fields in the control-root manifest" {
  local label issue_arguments expression name
  local -a words
  while IFS='@' read -r label issue_arguments expression; do
    [ -n "$label" ] || continue
    read -ra words <<< "$issue_arguments"
    issue_schema3 "$label" "write the web scope" directory:src/web "${words[@]}"
    generate_schema3
    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    name=$(generated_name web-engineer)
    jq -e --arg name "$name" --arg root "$S3_ROOT" "$expression" "$S3_ROOT/agent-manifest.json" >/dev/null \
      || { echo "case=$label expression=$expression" >&2; jq ".agents[\"$name\"]" "$S3_ROOT/agent-manifest.json" >&2; return 1; }
    [ -f "$TEST_TEMP_DIR/.claude/agents/$name.md" ] || { echo "case=$label definition missing for $name" >&2; return 1; }
  done <<'CASES'
control-root@@.agents[$name].schema_version == 3 and .agents[$name].control_root == $root and .agents[$name].capabilities == [{access:"write",kind:"directory",path:"src/web"}]
runtime-policy@--runtime-kind native-team --communication-policy native-team@.agents[$name].runtime_kind == "native-team" and .agents[$name].communication_policy == "native-team"
in-process-execution@@.agents[$name].execution.requested_backend == "in_process" and .agents[$name].execution.resolved_backend == "in_process" and .agents[$name].execution.role == "web-engineer" and .agents[$name].execution.model == .agents[$name].model and .agents[$name].execution.effort == .agents[$name].effort and .agents[$name].execution.max_turns == .agents[$name].max_turns and .agents[$name].execution.contract_id == .agents[$name].contract_id and (.agents[$name].execution | has("tmux_bootstrap") | not)
CASES
}

@test "schema 3 tmux runtime selection records matching execution metadata" {
  jq -e '."web-engineer".executionBackend == "in_process"' \
    "$PROJECT_ROOT/templates/agent-roles/defaults.json" >/dev/null
  issue_schema3 tmux-execution "write the web scope" directory:src/web \
    --requested-backend tmux --resolved-backend tmux
  generate_schema3 --execution-backend tmux
  [ "$status" -eq 0 ]
  local name
  name=$(generated_name web-engineer)
  [ -n "$name" ]
  jq -e --arg name "$name" '
    .agents[$name].execution.requested_backend == "tmux"
    and .agents[$name].execution.resolved_backend == "tmux"
    and .agents[$name].execution.role == .agents[$name].role
    and .agents[$name].execution.model == .agents[$name].model
    and .agents[$name].execution.effort == .agents[$name].effort
    and .agents[$name].execution.max_turns == .agents[$name].max_turns
    and .agents[$name].execution.contract_id == .agents[$name].contract_id
    and .agents[$name].execution.contract_digest == .agents[$name].contract_digest
    and .agents[$name].execution.task_identity == .agents[$name].task_identity
    and .agents[$name].execution.tmux_bootstrap.child_identity == $name
    and .agents[$name].execution.tmux_bootstrap.contract_id == .agents[$name].contract_id
    and .agents[$name].execution.tmux_bootstrap.control_root == .agents[$name].control_root
  ' "$S3_ROOT/agent-manifest.json" >/dev/null
  grep -F '## TMUX bus loop' "$TEST_TEMP_DIR/.claude/agents/$name.md"
}

@test "schema 3 generation rejects execution backend overrides before writing the manifest" {
  local label contract_backend override expected
  local -a contract_arguments
  while IFS='@' read -r label contract_backend override expected; do
    [ -n "$label" ] || continue
    contract_arguments=()
    [ "$contract_backend" = "-" ] || contract_arguments=(--requested-backend "$contract_backend" --resolved-backend "$contract_backend")
    issue_schema3 "$label" "write the web scope" directory:src/web "${contract_arguments[@]}"
    generate_schema3 --execution-backend "$override"
    [ "$status" -eq 1 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [[ "$output" == *"$expected"* ]] || { echo "case=$label expected=$expected output=$output" >&2; return 1; }
    [ ! -f "$S3_ROOT/agent-manifest.json" ] || { echo "case=$label manifest was written" >&2; return 1; }
  done <<'CASES'
backend-drift@tmux@in_process@execution backend override conflicts with contract
invalid-selection@-@unsupported@invalid execution backend override 'unsupported'
CASES
}

@test "native-team generation renders native capabilities and records definition authority" {
  local name
  issue_schema3 native-definition "implement the scoped task" directory:. \
    --runtime-kind native-team --communication-policy native-team
  generate_native_team
  [ "$status" -eq 0 ]
  name=$(generated_name web-engineer)
  [ -n "$name" ]
  grep -F 'SendMessage' "$TEST_TEMP_DIR/.claude/agents/$name.md" >/dev/null
  grep -F 'TaskList' "$TEST_TEMP_DIR/.claude/agents/$name.md" >/dev/null
  grep -F 'Write' "$TEST_TEMP_DIR/.claude/agents/$name.md" >/dev/null
  jq -e --arg name "$name" '.agents[$name].definition_sha256 != null and .agents[$name].tools != null' \
    "$S3_ROOT/agent-manifest.json" >/dev/null
}

@test "native-team generation rejects definition-field overrides" {
  issue_schema3 native-override "implement the scoped task" directory:.
  generate_native_team --model other-model
  [ "$status" -ne 0 ]
  [[ "$output" == *"native-team definition overrides are not allowed"* ]]
  [ "$(agent_file_count)" -eq 0 ]
}

@test "--pair with a pairsWith role prints ENGINEER and CRITIC SPAWN_READY lines" {
  generate --pair python-engineer --job "build a parser"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENGINEER: SPAWN_READY lbwc-python-engineer-"* ]]
  [[ "$output" == *"CRITIC: SPAWN_READY lbwc-python-critic-"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'SPAWN_READY')" -eq 2 ]
}

@test "trio grants an exact test allowance only to test-dev" {
  generate --trio python-engineer --job "add parser coverage" \
    --write-allowance src/parser.py \
    --role-write-allowance test-dev:tests/parser.bats
  [ "$status" -eq 0 ]
  jq -e '
    [.agents[] | select(.role == "python-engineer") | .write_allowances] == [["src/parser.py"]]
    and [.agents[] | select(.role == "test-dev") | .write_allowances] == [["tests/parser.bats"]]
    and [.agents[] | select(.role == "python-critic") | .write_allowances] == [[]]
  ' "$(manifest_path)" >/dev/null
}

@test "trio rejects role-scoped allowances that do not target an exact test path" {
  local label scoped expected
  while IFS='@' read -r label scoped expected; do
    [ -n "$label" ] || continue
    generate --trio python-engineer --job "add parser coverage" --role-write-allowance "$scoped"
    [ "$status" -eq 1 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [[ "$output" == *"$expected"* ]] || { echo "case=$label expected=$expected output=$output" >&2; return 1; }
  done <<'CASES'
critic-role@python-critic:reviews/parser.md@only valid for test-dev
test-dev-outside-tests@test-dev:src/parser.py@exact repository test path
CASES
}

@test "generator rejects a pair that would exceed the live-agent capacity" {
  generate --trio python-engineer --job "hold the current build slot"
  [ "$status" -eq 0 ]
  [ "$(jq '[.agents[] | select(.state == "registered")] | length' "$(manifest_path)")" -eq 3 ]

  generate --pair python-engineer --job "must wait for capacity"
  [ "$status" -eq 1 ]
  [[ "$output" == *"agent cap reached: 4"* ]]
  [ "$(jq '.agents | length' "$(manifest_path)")" -eq 3 ]
}

@test "--exclusive rejects generation while a solo agent is registered or running" {
  local state
  for state in registered running; do
    reset_generated_state
    seed_solo_agent "$state"
    generate --pair python-engineer --exclusive --job "must wait for the solo"
    assert_exclusive_blocked "solo-$state" "exclusive generation blocked: registered or running agent exists"
  done
}

@test "--exclusive admits generation after the solo agent becomes used or expired" {
  local state
  for state in used expired; do
    reset_generated_state
    seed_solo_agent "$state"
    generate --pair python-engineer --exclusive --job "start after the solo"
    assert_exclusive_admitted "solo-$state" "$state"
  done
}

@test "--exclusive fails closed for malformed lifecycle states" {
  local label transform
  while IFS='@' read -r label transform; do
    [ -n "$label" ] || continue
    reset_generated_state
    seed_solo_agent registered
    jq "$transform" "$(manifest_path)" > "$(manifest_path).tmp"
    mv "$(manifest_path).tmp" "$(manifest_path)"
    generate --pair python-engineer --exclusive --job "reject malformed state"
    assert_exclusive_blocked "$label" "exclusive generation blocked: invalid agent lifecycle state"
  done <<'CASES'
null-state@.agents[.agents | keys[0]].state = null
missing-state@del(.agents[.agents | keys[0]].state)
unknown-state@.agents[.agents | keys[0]].state = "paused"
array-entry@.agents[.agents | keys[0]] = []
number-entry@.agents[.agents | keys[0]] = 42
CASES
}

@test "contract mode rejects contracts that do not match the request" {
  local label team contract_allowances filter task requested expected contract id
  local -a request_arguments mode_arguments
  while IFS='@' read -r label team contract_allowances filter task requested expected; do
    [ -n "$label" ] || continue
    reset_generated_state
    contract=$(make_contract python-engineer "case-$label" "$contract_allowances" "$team" "contract job")
    jq "$filter" "$contract" > "$contract.tmp" && mv "$contract.tmp" "$contract"
    id=$(basename "$contract" .json)
    [ "$task" = "-" ] || id="$task"
    request_arguments=()
    for allowance in $requested; do request_arguments+=(--write-allowance "$allowance"); done
    mode_arguments=()
    [ "$team" = "pair" ] && mode_arguments=(--pair)
    generate "${mode_arguments[@]}" python-engineer --job "contract job" --task-id "$id" \
      --contract "$contract" "${request_arguments[@]}"
    assert_rejected_without_mutation "$label" "$expected"
  done <<'CASES'
tampered-digest@solo@["src/a.py"]@.task_identity = "tampered"@-@src/a.py@contract digest mismatch
task-identity-mismatch@solo@["src/a.py"]@.@task-2@src/a.py@task identity mismatch
extra-allowance@solo@["src/a.py"]@.@-@src/a.py src/b.py@write allowances do not match contract
subset-allowance@solo@["src/a.py","src/b.py"]@.@-@src/a.py@write allowances do not match contract
worker-provenance@solo@["src/a.py"]@.created_by = "worker"@-@src/a.py@contract digest mismatch|planned main-session contract
pair-missing-role@pair@["src/a.py"]@.roles = ["python-engineer"]@-@src/a.py@contract
CASES
}

@test "generator accepts a real task-contract writer output" {
  cat > "$TEST_TEMP_DIR/PLAN.md" <<'EOF'
phase: 09
<tasks>
<task><name>wire-contract</name><action>implement</action><verify>tests</verify><done>green</done><strategy>small</strategy><role>python-engineer</role><files>src/a.py</files></task>
</tasks>
EOF
  local contract id
  contract=$(bash "$SCRIPTS_DIR/task-contract.sh" open "$TEST_TEMP_DIR/PLAN.md" "$TEST_TEMP_DIR" wire-contract --team solo --job "wire contract")
  id=$(basename "$contract" .json)
  generate python-engineer --job "wire contract" --task-id "$id" --contract "$contract" --write-allowance src/a.py
  [ "$status" -eq 0 ]
  jq -e --arg id "$id" '.agents[] | select(.contract_id == $id and .contract_enabled == true)' "$(manifest_path)" >/dev/null
}
