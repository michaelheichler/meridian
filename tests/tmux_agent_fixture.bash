tmux_fixture_entry() {
  jq -cn --arg role "$role" \
    --arg name "$name" --arg root "$canonical_project_root" --arg control_root "$canonical_control_root" \
    --arg definition_path "$definition_path" --arg definition_digest "$definition_digest" \
    --arg contract_path "$contract" --arg contract_id "$contract_id" --arg contract_digest "$contract_digest" '
    {name:$name,role:$role,project_root:$root,control_root:$control_root,schema_version:3,
     definition_path:$definition_path,definition_sha256:$definition_digest,definition_authority:"generated-definition",
     state:"registered",model:"test-model",effort:"high",max_turns:1,contract_enabled:true,
     contract_path:$contract_path,contract_id:$contract_id,contract_digest:$contract_digest,task_identity:$contract_id,
     capabilities:[{access:"write",kind:"directory",path:"."}],write_allowances:["."],
     runtime_kind:"native-team",communication_policy:"native-team",
     execution:{role:$role,model:"test-model",effort:"high",max_turns:1,contract_id:$contract_id,
       contract_digest:$contract_digest,task_identity:$contract_id,requested_backend:"tmux",resolved_backend:"tmux",
       tmux_bootstrap:{child_identity:$name,contract_id:$contract_id,control_root:$control_root}}}'
}

prepare_tmux_agents() {
  local name contract contract_id contract_digest definition_path definition_digest manifest entry definitions='[]' canonical_project_root canonical_control_root role="${TMUX_FIXTURE_ROLE:-web-engineer}"
  mkdir -p "$PROJECT_ROOT/.claude/agents"
  canonical_project_root="$(cd "$PROJECT_ROOT" && pwd -P)"
  canonical_control_root="$(cd "$CONTROL_ROOT" && pwd -P)"
  for name in "$@"; do
    contract=$(bash "$REPO_ROOT/scripts/task-contract.sh" issue "$PROJECT_ROOT" "$name" \
      --command team --role "$role" --team solo --job "spawn $name" \
      --control-root "$CONTROL_ROOT" --runtime-kind native-team \
      --communication-policy native-team --requested-backend tmux --resolved-backend tmux \
      --write-capability directory:.) || return 1
    contract_id="$(basename "$contract" .json)"
    bash "$REPO_ROOT/scripts/task-contract.sh" state "$PROJECT_ROOT" "$contract_id" dispatched >/dev/null || return 1
    contract_digest="$(jq -r '.contract_digest' "$contract")"
    definition_path="$canonical_project_root/.claude/agents/$name.md"
    printf '%s\n' "generated definition for $name" > "$definition_path"
    definition_digest="$(shasum -a 256 "$definition_path" | cut -d ' ' -f 1)"
    manifest="${manifest:-$( [ -f "$CONTROL_ROOT/.agent-manifest.json" ] && cat "$CONTROL_ROOT/.agent-manifest.json" || printf '%s' '{"agents":{}}' )}"
    entry=$(tmux_fixture_entry) || return 1
    manifest=$(jq -c --arg name "$name" --argjson entry "$entry" '.agents[$name] = $entry' <<<"$manifest") || return 1
    definitions=$(jq -c --arg name "$name" --arg contract_id "$contract_id" --arg contract_digest "$contract_digest" \
      '. + [{agent_id:$name,generated_name:$name,contract_id:$contract_id,contract_digest:$contract_digest}]' <<<"$definitions") || return 1
  done
  printf '%s\n' "$manifest" > "$CONTROL_ROOT/.agent-manifest.json"
  printf '%s\n' "$definitions"
}
