GENERATED=()
TEAMMATES_JSON='[]'

prepare_create_run() {
  local scope
  local -a scope_args=()
  while IFS= read -r scope; do
    [ -n "$scope" ] && scope_args+=(--scope "$scope")
  done < <(jq -r '.[]' <<< "$RESOLVED_SCOPES")
  RUN_ROOT=$(bash "$SCRIPT_DIR/team-run-state.sh" create \
    --project-root "$PROJECT_ROOT" --run-id "$RUN_ID" ${scope_args[@]+"${scope_args[@]}"}) \
    || fail 'run creation failed'
}

prepare_seed_temporary_root() {
  local routing model reasoning
  CONTROL_ROOT="$RUN_ROOT"
  resolve_routing "$ROSTER_ENGINEER" routing
  model=$(jq -r '.model' <<< "$routing")
  reasoning=$(jq -c '.reasoning' <<< "$routing")
  jq -r '.catalog' <<< "$routing" > "$CONTROL_ROOT/claude-capabilities.json"
  jq -n \
    --arg model "$model" \
    --argjson reasoning "$reasoning" \
    --slurpfile defaults "$ROLE_DEFAULTS_PATH" \
    '{
      schema_version: 1,
      routing: {
        active_profile: "balanced",
        profiles: {
          quality: {roles: {}},
          balanced: {
            roles: ($defaults[0] | keys | map({key: ., value: {model: $model, reasoning: $reasoning, status: "resolved"}}) | from_entries)
          },
          turbo: {roles: {}}
        }
      }
    }' > "$CONTROL_ROOT/routing.json"
}

prepare_issue_contract() {
  local scope=""
  local -a capability_args=()
  while IFS= read -r scope; do
    [ -n "$scope" ] || continue
    capability_args+=(--role-write-capability "$ROSTER_ENGINEER:directory:$scope")
  done < <(jq -r '.[]' <<< "$RESOLVED_SCOPES")
  CONTRACT_PATH=$(bash "$SCRIPT_DIR/task-contract.sh" issue "$PROJECT_ROOT" "$RUN_ID" \
    --command team --role "$ROSTER_ENGINEER" --team "$TEAM_MODE" --job "$INSTRUCTION" \
    --control-root "$CONTROL_ROOT" --runtime-kind native-team --communication-policy native-team \
    --requested-backend in_process --resolved-backend in_process \
    ${capability_args[@]+"${capability_args[@]}"}) \
    || fail_diag 'contract issue failed'
  CONTRACT_ID=$(basename "$CONTRACT_PATH" .json)
  CONTRACT_JSON=$(bash "$SCRIPT_DIR/task-contract.sh" verify "$CONTRACT_PATH" "$PROJECT_ROOT") \
    || fail_diag 'contract verification failed'
  CONTRACT_REQUESTED_BACKEND=$(jq -r '.requested_backend' <<< "$CONTRACT_JSON")
  CONTRACT_RESOLVED_BACKEND=$(jq -r '.resolved_backend' <<< "$CONTRACT_JSON")
}

prepare_generate_agents() {
  local scope line name generator_output
  local -a generator_args=(--native-team)
  GENERATED=()
  if [ "$TEAM_MODE" = "trio" ]; then
    generator_args+=(--trio "$ROSTER_ENGINEER")
  else
    generator_args+=(--pair "$ROSTER_ENGINEER")
  fi
  generator_args+=(--job "$INSTRUCTION" \
    --contract "$CONTRACT_PATH" --task-id "$CONTRACT_ID" --control-root "$CONTROL_ROOT")
  while IFS= read -r scope; do
    [ -n "$scope" ] || continue
    generator_args+=(--write-capability "directory:$scope")
  done < <(jq -r '.[]' <<< "$RESOLVED_SCOPES")
  generator_output=$(bash "$SCRIPT_DIR/agent-generator.sh" "${generator_args[@]}") \
    || fail_diag "agent generation failed for '$TEAM_MODE' rooted at '$ROSTER_ENGINEER': $generator_output"
  while IFS= read -r line; do
    case "$line" in
      SPAWN_READY\ *|*': SPAWN_READY '*)
        name="${line##*SPAWN_READY }"
        [ -n "$name" ] || fail_diag 'generator reported an empty spawn-ready name'
        GENERATED+=("$name")
        ;;
    esac
  done <<< "$generator_output"
  [ "${#GENERATED[@]}" -eq "$(jq 'length' <<< "$ROSTER_ROLES_JSON")" ] \
    || fail_diag "generator registered ${#GENERATED[@]} names for a $(jq 'length' <<< "$ROSTER_ROLES_JSON")-role roster"
}

prepare_collect_teammates() {
  local manifest_read_path name role
  TEAMMATES_JSON='[]'
  manifest_read_path=$(lbwc_control_root_manifest_path "$CONTROL_ROOT") || fail_diag 'control root manifest path is unavailable'
  while IFS= read -r name; do
    role=$(jq -r --arg name "$name" '.agents[$name].role // empty' "$manifest_read_path")
    [ -n "$role" ] || fail_diag "generated name '$name' is not registered in the run manifest"
    TEAMMATES_JSON=$(jq -c --arg name "$name" --arg role "$role" '. + [{name:$name,role:$role}]' <<< "$TEAMMATES_JSON")
  done < <(printf '%s\n' ${GENERATED[@]+"${GENERATED[@]}"})
}

prepare_record_run() {
  local updated_run
  bash "$SCRIPT_DIR/task-contract.sh" state "$PROJECT_ROOT" "$CONTRACT_ID" dispatched >/dev/null \
    || fail_diag 'contract dispatch failed'
  jq -cn --arg id "$CONTRACT_ID" --arg requested "$CONTRACT_REQUESTED_BACKEND" --arg resolved "$CONTRACT_RESOLVED_BACKEND" \
    '{schema_version:3,contract_id:$id,status:"dispatched",requested_backend:$requested,resolved_backend:$resolved}' \
    > "$RUN_ROOT/contract.json"
  updated_run=$(jq -c --argjson teammates "$TEAMMATES_JSON" --arg contract "$CONTRACT_ID" \
    --arg team_mode "$TEAM_MODE" --arg control_root "$CONTROL_ROOT" \
    --arg requested_backend "$CONTRACT_REQUESTED_BACKEND" --arg resolved_backend "$CONTRACT_RESOLVED_BACKEND" \
    '.records = (.records // {})
     | .records["contract:\($contract)"] = {kind:"contract",id:$contract,status:"dispatched",updated_at:(now | todate)}
     | .teammates = $teammates
     | .team_mode = $team_mode
     | .control_root = $control_root
     | .requested_backend = $requested_backend
     | .resolved_backend = $resolved_backend
     | .updated_at = (now | todate)' "$RUN_ROOT/run.json") \
    || fail_diag 'run state update failed'
  printf '%s\n' "$updated_run" > "$RUN_ROOT/run.json"
  printf '%s\n' "$(jq -cn --arg id "$CONTRACT_ID" --argjson teammates "$TEAMMATES_JSON" \
    '{event:"prepare",contract_id:$id,teammates:$teammates,at:(now | todate)}')" \
    >> "$RUN_ROOT/diagnostics.jsonl" || fail_diag 'diagnostics append failed'
}

prepare_emit_result() {
  jq -n \
    --arg run_root "$RUN_ROOT" \
    --arg control_root "$CONTROL_ROOT" \
    --arg control_root_kind "$CONTROL_ROOT_KIND" \
    --arg contract_path "$CONTRACT_PATH" \
    --arg contract_id "$CONTRACT_ID" \
    --arg team_mode "$TEAM_MODE" \
    --arg requested_backend "$CONTRACT_REQUESTED_BACKEND" --arg resolved_backend "$CONTRACT_RESOLVED_BACKEND" \
    --argjson teammates "$TEAMMATES_JSON" \
    --argjson scopes "$RESOLVED_SCOPES" \
    --arg engineer "$ROSTER_ENGINEER" \
    '{schema_version:3,run_root:$run_root,control_root:$control_root,
      control_root_kind:$control_root_kind,contract_path:$contract_path,contract_id:$contract_id,
      team_mode:$team_mode,teammates:$teammates,scopes:$scopes,engineer:$engineer,
       requested_backend:$requested_backend,resolved_backend:$resolved_backend,
      contract_state:"dispatched",task_subject:$contract_id,
      ordered_actions:["agent_spawn","task_create"]}'
}

action_prepare() {
  PROJECT_ROOT=$(canonical_project_root "$PROJECT_ROOT_ARG")
  [ -n "$RUN_ID" ] || fail '--run-id is required'
  is_valid_run_id "$RUN_ID" || fail 'run id is invalid'
  [ -n "$INSTRUCTION" ] || fail '--instruction is required'
  resolve_scopes
  reject_protected_scopes
  resolve_active_control_root
  resolve_roster ROSTER_ENGINEER ROSTER_CRITIC ROSTER_TEST_DEV TEAM_MODE ROSTER_ROLES_JSON
  prepare_create_run
  CONTROL_ROOT="$ACTIVE_CONTROL_ROOT"
  if [ "$CONTROL_ROOT_KIND" = "temporary-run" ]; then
    prepare_seed_temporary_root
  fi
  prepare_issue_contract
  prepare_generate_agents
  prepare_collect_teammates
  prepare_record_run
  prepare_emit_result
}
