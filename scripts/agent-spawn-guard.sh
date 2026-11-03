#!/bin/bash
set -u
. "$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd)/lib/debug-logging.sh" 2>/dev/null || true
debug_logging_gate agent-spawn-guard.sh PreToolUse 2>/dev/null || true

command -v jq >/dev/null 2>&1 || {
  echo "Blocked: jq not available, cannot validate agent spawn" >&2
  exit 2
}

fail() {
  echo "Blocked: $1" >&2
  exit 2
}

INPUT=$(cat 2>/dev/null) || fail "agent spawn guard could not read tool call input"
[ -z "$INPUT" ] && exit 0

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/lib/agent-manifest.sh" ] || fail "agent manifest library is unavailable"
. "$SCRIPT_DIR/lib/agent-manifest.sh" || fail "agent manifest library failed to load"
[ -f "$SCRIPT_DIR/lib/lbwc-control-root.sh" ] || fail "control root library is unavailable"
. "$SCRIPT_DIR/lib/lbwc-control-root.sh" || fail "control root library failed to load"
. "$SCRIPT_DIR/lib/lbwc-config-files.sh" || fail "config library failed to load"
. "$SCRIPT_DIR/lib/worktree-isolation.sh" || fail "worktree isolation library failed to load"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || fail "agent spawn guard could not parse tool call input"
case "$TOOL_NAME" in
  Agent|TaskCreate) ;;
  *) exit 0 ;;
esac

SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // .tool_input.agent_type // .tool_input.name // ""' 2>/dev/null) \
  || fail "agent spawn guard could not parse subagent type"

block_unresolved_generated_identity() {
  case "$SUBAGENT_TYPE" in
    lbwc-*) echo "Blocked: generated LBWC identity has no resolvable control root or manifest" >&2; exit 2 ;;
  esac
  exit 0
}

CONTROL_ROOT=$(lbwc_resolve_control_root "" "" "$PWD" 2>/dev/null || true)
[ -n "$CONTROL_ROOT" ] || block_unresolved_generated_identity
PROJECT_ROOT=$(lbwc_control_root_project_root "$CONTROL_ROOT" 2>/dev/null || true)
[ -n "$PROJECT_ROOT" ] || block_unresolved_generated_identity
PLANNING_DIR="$CONTROL_ROOT"
MANIFEST_PATH=$(agent_manifest_path "$PLANNING_DIR" 2>/dev/null) || block_unresolved_generated_identity
requested_cwd_values() {
  echo "$INPUT" | jq -r '[.tool_input.cwd? // empty, .tool_input.working_dir? // empty, .tool_input.workingDirectory? // empty, .tool_input.workdir? // empty] | map(select(type == "string")) | .[]' 2>/dev/null \
    || return 1
}

requested_sidechain_cwd() {
  requested_cwd_values | grep -Eq '(^|/)\.lbwc-worktrees/agent-[^/]+(/|$)'
}

requested_worktree_isolation() {
  local isolation=""
  isolation=$(echo "$INPUT" | jq -r '.tool_input.isolation // ""' 2>/dev/null) || return 1
  [ "$isolation" = "worktree" ]
}

enforce_worktree_isolation() {
  local role="$SUBAGENT_TYPE"
  [ ! -f "$MANIFEST_PATH" ] || role=$(jq -r --arg name "$SUBAGENT_TYPE" '.agents[$name].role // $name' "$MANIFEST_PATH") || fail 'cannot read worker role'
  if worker_may_write_code "$role"; then
    requested_worktree_isolation || fail 'worktree_isolation is on, code-writing workers require isolation="worktree"'
    printf -v ISOLATED_CODE_WRITER '%s' true
  fi
}

ISOLATED_CODE_WRITER=false
ISOLATION_REQUIRED=false
if worktree_isolation_enabled "$CONTROL_ROOT"; then
  ISOLATION_REQUIRED=true
  if [ -n "$SUBAGENT_TYPE" ] || [ "$TOOL_NAME" = Agent ]; then
    enforce_worktree_isolation
  fi
fi
STRIP_REASON=""
STRIP_WARN=""
STRIPPED_INPUT=""
if [ "$ISOLATED_CODE_WRITER" = true ] || { [ "$ISOLATION_REQUIRED" = true ] && requested_sidechain_cwd; }; then
  STRIPPED_INPUT=$(echo "$INPUT" | jq '.tool_input | del(.cwd, .working_dir, .workingDirectory, .workdir)' 2>/dev/null)
  STRIP_REASON="lbwc stripped sidechain cwd fields and preserved required isolation"
elif requested_sidechain_cwd; then
  STRIPPED_INPUT=$(echo "$INPUT" | jq '.tool_input | del(.cwd, .working_dir, .workingDirectory, .workdir, .isolation)' 2>/dev/null)
  STRIP_REASON="lbwc stripped sidechain cwd fields, worktree targeting is task metadata, not spawn cwd"
  STRIP_WARN="lbwc guard: stripped sidechain cwd fields from spawn (models add these spontaneously, blocking causes retry loops)"
elif [ "$ISOLATION_REQUIRED" = false ] && requested_worktree_isolation; then
  STRIPPED_INPUT=$(echo "$INPUT" | jq '.tool_input | del(.isolation)' 2>/dev/null)
  STRIP_REASON="lbwc stripped isolation:worktree, worktree isolation is not managed via spawn params"
  STRIP_WARN="lbwc guard: stripped isolation:worktree from spawn (models add this spontaneously, blocking causes retry loops)"
fi

emit_updated_input() {
  local updated_input="$1" reason="$2" compact_input
  compact_input=$(echo "$updated_input" | jq -c '.' 2>/dev/null) || compact_input="$updated_input"
  jq -n -c --arg reason "$reason" --argjson input "$compact_input" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$reason,"updatedInput":$input}}'
}

allow_with_strip() {
  if [ -n "$STRIP_REASON" ] && [ -n "$STRIPPED_INPUT" ] && [ "$STRIPPED_INPUT" != "null" ]; then
    [ -n "$STRIP_WARN" ] && echo "$STRIP_WARN" >&2
    emit_updated_input "$STRIPPED_INPUT" "$STRIP_REASON"
  fi
  exit 0
}

if [ ! -f "$MANIFEST_PATH" ]; then
  case "$SUBAGENT_TYPE" in
    lbwc-*) block_unresolved_generated_identity ;;
    *) [ "$ISOLATED_CODE_WRITER" != true ] || allow_with_strip ;;
  esac
  block_unresolved_generated_identity
fi
[ -n "$SUBAGENT_TYPE" ] || allow_with_strip

find_blocking_open_pair() {
  local manifest="$1" name="$2"
  jq -c --arg name "$name" '
    def reached_running: (.state == "running") or (.state == "used") or (.state == "expired");
    (.agents | to_entries
      | map(select(.value.pair_id != null))
      | group_by(.value.pair_id)
      | map(select(length > 1))
      | map(select((map(.value | reached_running) | all) | not))
    ) as $open
    | ($open | map(select(any(.[]; .key == $name) | not))) as $blocking
    | if ($blocking | length) > 0 then
        ($blocking[0] | sort_by(.value.pair_role // .value.role)) as $sorted
        | {pair_id: $sorted[0].value.pair_id,
           members: [$sorted[] | {role: (.value.pair_role // .value.role), name: .key}]}
      else empty end
  ' <<< "$manifest" 2>/dev/null
}

contract_runtime_matches() {
  local entry="$1" contract="$2" runtime_kind communication_policy
  [ "$(jq -r '.schema_version' <<< "$contract")" = "3" ] || return 0
  runtime_kind=$(jq -r '.runtime_kind // empty' <<< "$contract")
  communication_policy=$(jq -r '.communication_policy // empty' <<< "$contract")
  jq -e --arg runtime "$runtime_kind" --arg policy "$communication_policy" '
    .runtime_kind == $runtime and .communication_policy == $policy
  ' <<< "$entry" >/dev/null 2>&1 || return 2
}

contract_capabilities_match() {
  local entry="$1" contract="$2" role capabilities
  [ "$(jq -r '.schema_version' <<< "$contract")" = "3" ] || return 0
  role=$(jq -r '.role // empty' <<< "$entry")
  capabilities=$(jq -c '.capabilities // []' <<< "$entry")
  jq -e --arg role "$role" --argjson capabilities "$capabilities" '.capabilities_by_role[$role] == $capabilities' <<< "$contract" >/dev/null 2>&1 || return 2
}

contract_team_matches() {
  local entry="$1" contract="$2" manifest="$3" team_mode pair_id manifest_roles contract_roles
  team_mode=$(jq -r '.team_mode' <<< "$contract")
  pair_id=$(jq -r '.pair_id // empty' <<< "$entry")
  if [ "$team_mode" = "solo" ]; then
    [ -z "$pair_id" ] || return 1
  else
    [ -n "$pair_id" ] || return 1
    manifest_roles=$(jq -c --arg pair "$pair_id" '[.agents[] | select(.pair_id == $pair) | .role]' <<< "$manifest") || return 1
    contract_roles=$(jq -c '.roles' <<< "$contract") || return 1
    [ "$manifest_roles" = "$contract_roles" ] || return 1
  fi
}

contract_identity_matches() {
  local entry="$1" contract="$2" contract_id contract_digest task_identity role allowances
  contract_id=$(jq -r '.contract_id // empty' <<< "$contract")
  contract_digest=$(jq -r '.contract_digest // empty' <<< "$contract")
  task_identity=$(jq -r '.task_identity // empty' <<< "$contract")
  role=$(jq -r '.role // empty' <<< "$entry")
  allowances=$(jq -c '.write_allowances // []' <<< "$entry")
  jq -e --arg id "$contract_id" --arg digest "$contract_digest" --arg task "$task_identity" \
    --arg role "$role" --argjson allowances "$allowances" '
      .contract_enabled == true
      and .contract_id == $id
      and .contract_digest == $digest
      and .task_identity == $task
      and .role == $role
      and $id != ""
    ' <<< "$entry" >/dev/null 2>&1 || return 1
  jq -e --arg role "$role" --argjson allowances "$allowances" '.allowances_by_role[$role] == $allowances' <<< "$contract" >/dev/null 2>&1 || return 1
}

validate_entry_contract() {
  local name="$1" entry="$2" manifest="$3" contract_path contract
  contract_path=$(jq -r '.contract_path // empty' <<< "$entry")
  [ -n "$contract_path" ] || return 1
  contract=$(bash "$SCRIPT_DIR/task-contract.sh" verify "$contract_path" "$PROJECT_ROOT" 2>/dev/null) || return 1
  jq -e '.state == "dispatched"' <<< "$contract" >/dev/null 2>&1 || return 1
  contract_runtime_matches "$entry" "$contract" || return $?
  contract_identity_matches "$entry" "$contract" || return $?
  contract_capabilities_match "$entry" "$contract" || return $?
  contract_team_matches "$entry" "$contract" "$manifest" || return $?
  return 0
}

map_manifest_model() {
  local selector="$1" catalog="$PLANNING_DIR/claude-capabilities.json" mapped source
  [ -n "$selector" ] || { printf '%s\n' ""; return 0; }
  if [ -f "$catalog" ]; then
    source="$catalog"
  elif [ -n "${CLAUDE_CODE_EXECPATH:-}" ]; then
    source="$CLAUDE_CODE_EXECPATH"
  else
    source=$(command -v claude 2>/dev/null || true)
  fi
  [ -n "$source" ] || return 1
  mapped=$(bash "$SCRIPT_DIR/claude-capabilities.sh" map-agent-model "$source" "$selector" 2>/dev/null) || return 1
  [ -n "$mapped" ] || return 1
  printf '%s\n' "$mapped"
}

validate_native_call_authority() {
  local entry="$1" call_input actual expected field
  jq -e '.runtime_kind == "native-team"' <<< "$entry" >/dev/null 2>&1 || return 0
  call_input=$(jq -c '.tool_input // {}' <<< "$INPUT") || return 1
  for field in model maxTurns effort tools; do
    jq -e --arg field "$field" 'has($field) and .[$field] != null' <<< "$call_input" >/dev/null 2>&1 || continue
    actual=$(jq -c --arg field "$field" '.[$field]' <<< "$call_input") || return 1
    case "$field" in
      model)
        NATIVE_CONFLICT_FIELD="$field"
        expected=$(jq -r '.model' <<< "$entry")
        actual=$(jq -r '.model' <<< "$call_input")
        expected=$(map_manifest_model "$expected") || return 32
        actual=$(map_manifest_model "$actual") || return 32
        expected=$(jq -cn --arg value "$expected" '$value')
        actual=$(jq -cn --arg value "$actual" '$value')
        ;;
      maxTurns) expected=$(jq -c '.max_turns | tostring' <<< "$entry"); actual=$(jq -c 'tostring' <<< "$actual") ;;
      effort) expected=$(jq -c '.effort' <<< "$entry") ;;
      tools) expected=$(jq -c '.tools' <<< "$entry") ;;
    esac
    if [ "$actual" != "$expected" ]; then
      NATIVE_CONFLICT_FIELD="$field"
      return 32
    fi
  done
  return 0
}

_mark_manifest_running() {
  local name="$1" manifest="$2" entry="$3" spawn_fields current now updated mapped_model
  spawn_fields=$(jq -c '{model, maxTurns, permissionMode} | with_entries(select(.value != null))' <<< "$entry" 2>/dev/null) || return 1
  mapped_model=$(jq -r '.model // empty' <<< "$spawn_fields")
  if [ -n "$mapped_model" ]; then
    mapped_model=$(map_manifest_model "$mapped_model") || return 33
    spawn_fields=$(jq -c --arg model "$mapped_model" '.model = $model' <<< "$spawn_fields") || return 1
  fi
  current="$STRIPPED_INPUT"
  [ -n "$current" ] && [ "$current" != null ] || current=$(echo "$INPUT" | jq '.tool_input' 2>/dev/null) || return 1
  STRIPPED_INPUT=$(jq --argjson spawn "$spawn_fields" '. * $spawn' <<< "$current") || return 1

  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || return 1
  updated=$(jq --arg name "$name" --arg now "$now" '
    .agents[$name].state = "running"
    | .agents[$name].started_at = $now
    | .agents[$name].last_activity_at = $now
  ' <<< "$manifest") || return 1
  agent_manifest_write "$PLANNING_DIR" "$updated" >/dev/null 2>&1 || return 1
  STRIP_REASON="${STRIP_REASON:+$STRIP_REASON; }enforced registered agent manifest for $name"
  return 0
}

_claim_manifest_spawn_locked() {
  local name="$1" manifest entry blocking state
  manifest=$(agent_manifest_read "$PLANNING_DIR" 2>/dev/null) || return 1
  entry=$(jq -c --arg name "$name" '.agents[$name] // empty' <<< "$manifest" 2>/dev/null) || return 1
  [ -n "$entry" ] || return 10
  validate_entry_contract "$name" "$entry" "$manifest"
  contract_status=$?
  [ "$contract_status" -eq 0 ] || { [ "$contract_status" -eq 2 ] && return 31; return 30; }
  validate_native_call_authority "$entry"
  native_call_status=$?
  [ "$native_call_status" -eq 0 ] || return "$native_call_status"

  blocking=$(find_blocking_open_pair "$manifest" "$name")
  if [ -n "$blocking" ]; then
    PAIR_ID=$(jq -r '.pair_id' <<< "$blocking")
    PAIR_MEMBERS=$(jq -r '[.members[] | "\(.role) (\(.name))"] | join(", ")' <<< "$blocking")
    return 20
  fi

  state=$(jq -r '.state // ""' <<< "$entry" 2>/dev/null) || state=""
  case "$state" in
    registered) ;;
    running|used|expired) CLAIM_STATE="$state"; return 3 ;;
    *) CLAIM_STATE="$state"; return 3 ;;
  esac

  _mark_manifest_running "$name" "$manifest" "$entry"
}

claim_manifest_spawn() {
  agent_manifest_with_lock "$PLANNING_DIR" _claim_manifest_spawn_locked "$1"
}

block_claim_failure() {
  local message
  case "$1" in
    20) message="Pair ${PAIR_ID:-} (${PAIR_MEMBERS:-?}) is open, spawn every member before starting other work." ;;
    30) message="generated agent '$SUBAGENT_TYPE' contract is missing, stale, tampered, or not dispatched." ;;
    31) message="generated agent '$SUBAGENT_TYPE' runtime or communication policy does not match its contract." ;;
    32) message="call-time ${NATIVE_CONFLICT_FIELD:-value} override conflicts with generated definition." ;;
    33) message="generated agent '$SUBAGENT_TYPE' model is not present in the live host Agent enum." ;;
    3) message="generated agent '$SUBAGENT_TYPE' is already ${CLAIM_STATE:-unregistered} and cannot be spawned again." ;;
    *) message="registered agent '$SUBAGENT_TYPE' could not be claimed." ;;
  esac
  echo "Blocked: $message" >&2
  exit 2
}

manifest_guard() {
  local claim_status
  claim_manifest_spawn "$SUBAGENT_TYPE"
  claim_status=$?
  case "$claim_status" in
    0) return 0 ;;
    10)
      case "$SUBAGENT_TYPE" in
        lbwc-*)
          echo "Blocked: agent '$SUBAGENT_TYPE' has no manifest entry, spawn it through the generator first." >&2
          exit 2
          ;;
        *) return 0 ;;
      esac
      ;;
    *) block_claim_failure "$claim_status" ;;
  esac
}

manifest_guard
allow_with_strip
