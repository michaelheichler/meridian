GENERATOR_ERROR=""
MANIFEST=""
TRIO_NAMES=()
ENGINEER_NAME=""
ENGINEER_TARGET=""
CRITIC_NAME=""
CRITIC_TARGET=""
SINGLE_NAME=""
SINGLE_TARGET=""

manifest_live_count() {
  local now
  now=$(date -u +%s)
  jq --arg now "$now" --argjson max_age "$LIVE_AGENT_MAX_AGE_SECONDS" '
    [.agents[] | select(
        .state == "running"
        or (.state == "registered" and ((($now | tonumber) - (.created_at | fromdateiso8601)) < $max_age))
      )] | length
  ' <<< "$MANIFEST"
}

rollback_targets() {
  local target
  for target in "$@"; do rm -f "$target"; done
}

render_role_or_rollback() {
  local role="$1" label="$2"
  shift 2
  if ! render_and_install_one "$role"; then
    rollback_targets "$@"
    declare -g GENERATOR_ERROR="could not render generated $label agent"
    return 1
  fi
}

write_manifest_or_rollback() {
  local what="$1"
  shift
  if ! agent_manifest_write "$PLANNING_DIR" "$MANIFEST"; then
    rollback_targets "$@"
    declare -g GENERATOR_ERROR="could not register generated $what in manifest"
    return 1
  fi
}

check_exclusive_generation() {
  [ -n "$EXCLUSIVE_MODE" ] || return 0
  if ! jq -e '
    all(.agents[];
      if type != "object" then false
      else .state as $state
        | ($state | type) == "string"
          and (["registered", "running", "used", "expired"] | index($state) != null)
      end
    )
  ' <<< "$MANIFEST" >/dev/null; then
    declare -g GENERATOR_ERROR="exclusive generation blocked: invalid agent lifecycle state"
    return 1
  fi
  if jq -e '
    .agents[] | select(.state == "registered" or .state == "running")
  ' <<< "$MANIFEST" >/dev/null; then
    declare -g GENERATOR_ERROR="exclusive generation blocked: registered or running agent exists"
    return 1
  fi
}

check_agent_cap() {
  local cap="${LBWC_AGENT_CAP:-$DEFAULT_AGENT_CAP}" needed=1 live
  [ -n "$PAIR_MODE" ] && needed=2
  [ -n "$TRIO_MODE" ] && needed="${#TRIO_ROLES[@]}"
  live=$(manifest_live_count)
  if [ $((live + needed)) -gt "$cap" ]; then
    declare -g GENERATOR_ERROR="agent cap reached: $cap live (running, or registered under 1h old) agents"
    return 1
  fi
}

generate_trio_locked() {
  local pair_id names=() targets=() role overrides_json allowances_json i
  pair_id=$(manifest_new_pair_id)
  for role in "${TRIO_ROLES[@]}"; do
    render_role_or_rollback "$role" "$role" "${targets[@]}" || return 1
    names+=("$NAME")
    targets+=("$TARGET")
  done
  overrides_json=$(build_overrides_json)
  for i in "${!TRIO_ROLES[@]}"; do
    allowances_json=$(build_write_allowances_json "${TRIO_ROLES[$i]}")
    register_entry "${names[$i]}" "${TRIO_ROLES[$i]}" "${targets[$i]}" "$pair_id" "${TRIO_ROLES[$i]}" "$overrides_json" "$allowances_json"
  done
  write_manifest_or_rollback "agent trio" "${targets[@]}" || return 1
  declare -g TRIO_NAMES=("${names[@]}")
}

generate_pair_locked() {
  local pair_id overrides_json allowances_json
  pair_id=$(manifest_new_pair_id)
  render_role_or_rollback "$ROLE" "engineer" || return 1
  declare -g ENGINEER_NAME="$NAME"
  declare -g ENGINEER_TARGET="$TARGET"
  render_role_or_rollback "$PAIR_ROLE" "critic" "$ENGINEER_TARGET" || return 1
  declare -g CRITIC_NAME="$NAME"
  declare -g CRITIC_TARGET="$TARGET"
  overrides_json=$(build_overrides_json)
  allowances_json=$(build_write_allowances_json "$ROLE")
  register_entry "$ENGINEER_NAME" "$ROLE" "$ENGINEER_TARGET" "$pair_id" "engineer" "$overrides_json" "$allowances_json"
  allowances_json=$(build_write_allowances_json "$PAIR_ROLE")
  register_entry "$CRITIC_NAME" "$PAIR_ROLE" "$CRITIC_TARGET" "$pair_id" "critic" "$overrides_json" "$allowances_json"
  write_manifest_or_rollback "agent pair" "$ENGINEER_TARGET" "$CRITIC_TARGET" || return 1
}

generate_single_locked() {
  local overrides_json allowances_json
  render_role_or_rollback "$ROLE" "agent" || return 1
  declare -g SINGLE_NAME="$NAME"
  declare -g SINGLE_TARGET="$TARGET"
  overrides_json=$(build_overrides_json)
  allowances_json=$(build_write_allowances_json "$ROLE")
  register_entry "$SINGLE_NAME" "$ROLE" "$SINGLE_TARGET" "" "" "$overrides_json" "$allowances_json"
  write_manifest_or_rollback "agent" "$SINGLE_TARGET" || return 1
}

generate_agent_locked() {
  local manifest
  manifest=$(agent_manifest_read "$PLANNING_DIR") || { declare -g GENERATOR_ERROR="invalid agent manifest"; return 1; }
  declare -g MANIFEST="$manifest"
  check_exclusive_generation || return 1
  check_agent_cap || return 1
  if [ -n "$TRIO_MODE" ]; then
    generate_trio_locked
  elif [ -n "$PAIR_MODE" ]; then
    generate_pair_locked
  else
    generate_single_locked
  fi
}

print_spawn_ready() {
  local role="$1" name="$2" label="$3"
  printf 'Agent-call parameters:\n'
  printf '  subagent_type: %s\n' "$name"
  printf '  name: %s\n' "$name"
  printf '  model: %s\n' "${ROLE_MODEL[$role]}"
  [ -n "${ROLE_MAXTURNS[$role]}" ] && printf '  maxTurns: %s\n' "${ROLE_MAXTURNS[$role]}"
  [ -n "${ROLE_EFFORT[$role]}" ] && printf '  effort: %s\n' "${ROLE_EFFORT[$role]}"
  if [ -n "$label" ]; then
    printf '%s: SPAWN_READY %s\n' "$label" "$name"
  else
    printf 'SPAWN_READY %s\n' "$name"
  fi
}

print_all_spawn_ready() {
  local i
  if [ -n "$TRIO_MODE" ]; then
    for i in "${!TRIO_ROLES[@]}"; do
      print_spawn_ready "${TRIO_ROLES[$i]}" "${TRIO_NAMES[$i]}" "${TRIO_ROLES[$i]^^}"
    done
  elif [ -n "$PAIR_MODE" ]; then
    print_spawn_ready "$ROLE" "$ENGINEER_NAME" "ENGINEER"
    print_spawn_ready "$PAIR_ROLE" "$CRITIC_NAME" "CRITIC"
  else
    print_spawn_ready "$ROLE" "$SINGLE_NAME" ""
  fi
}
