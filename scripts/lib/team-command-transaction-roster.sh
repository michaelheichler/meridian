check_roster_critic() {
  local engineer_role="$1" seen_critic="$2" critic_role="$3" out_critic="$4" configured_critic
  configured_critic=$(jq -r --arg role "$engineer_role" '.[$role].pairsWith // empty' "$ROLE_DEFAULTS_PATH")
  if [ "$seen_critic" = true ]; then
    [ -n "$configured_critic" ] || fail "role '$engineer_role' has no configured critic"
    [ "$critic_role" = "$configured_critic" ] \
      || fail "critic '$critic_role' is not the configured pair for '$engineer_role' ($configured_critic)"
  else
    [ -n "$configured_critic" ] || fail "role '$engineer_role' has no configured pair; pass its critic explicitly"
    critic_role="$configured_critic"
  fi
  printf -v "$out_critic" '%s' "$critic_role"
}

resolve_roster_from_roles() {
  local out_engineer="$1" out_critic="$2" out_test_dev="$3"
  local role picked_engineer="" picked_critic="" seen_critic=false seen_testdev=false engineer_count=0
  for role in "${ROLES[@]}"; do
    is_valid_role "$role" || fail "invalid role: $role"
    if [ "$role" = "test-dev" ]; then
      [ "$seen_testdev" = false ] || fail 'duplicate role: test-dev'
      seen_testdev=true
    elif is_critic_role "$role"; then
      [ "$seen_critic" = false ] || fail 'roster accepts at most one critic'
      seen_critic=true
      picked_critic="$role"
    else
      engineer_count=$((engineer_count + 1))
      [ "$engineer_count" -eq 1 ] || fail 'roster accepts exactly one engineer role'
      picked_engineer="$role"
    fi
  done
  [ -n "$picked_engineer" ] || fail 'roster requires one engineer role'
  check_roster_critic "$picked_engineer" "$seen_critic" "$picked_critic" picked_critic
  printf -v "$out_engineer" '%s' "$picked_engineer"
  printf -v "$out_critic" '%s' "$picked_critic"
  printf -v "$out_test_dev" '%s' "$seen_testdev"
}

resolve_roster_from_defaults() {
  local out_engineer="$1" out_critic="$2" out_test_dev="$3" picked_engineer configured_critic
  picked_engineer="${ENGINEER_ARG:-web-engineer}"
  is_valid_role "$picked_engineer" || fail "invalid engineer role: $picked_engineer"
  configured_critic=$(jq -r --arg role "$picked_engineer" '.[$role].pairsWith // empty' "$ROLE_DEFAULTS_PATH")
  [ -n "$configured_critic" ] || fail "engineer role '$picked_engineer' has no configured critic"
  printf -v "$out_engineer" '%s' "$picked_engineer"
  printf -v "$out_critic" '%s' "$configured_critic"
  printf -v "$out_test_dev" '%s' "$WANT_TEST_DEV"
}

resolve_roster() {
  local out_engineer="$1" out_critic="$2" out_test_dev="$3" out_team_mode="$4" out_roles_json="$5"
  local engineer="" critic="" test_dev=false team_mode roles_json
  if [ "${#ROLES[@]}" -gt 0 ]; then
    resolve_roster_from_roles engineer critic test_dev
  else
    resolve_roster_from_defaults engineer critic test_dev
  fi
  if [ "$test_dev" = true ]; then
    jq -e --arg role "$engineer" '.trios[$role] != null' "$ROLE_DEFAULTS_PATH" >/dev/null \
      || fail "role '$engineer' has no configured trio for test-dev"
    team_mode="trio"
  else
    team_mode="pair"
  fi
  roles_json=$(jq -cn \
    --arg engineer "$engineer" --arg critic "$critic" --argjson test_dev "$test_dev" \
    '[$engineer, $critic] + (if $test_dev then ["test-dev"] else [] end)')
  printf -v "$out_engineer" '%s' "$engineer"
  printf -v "$out_critic" '%s' "$critic"
  printf -v "$out_test_dev" '%s' "$test_dev"
  printf -v "$out_team_mode" '%s' "$team_mode"
  printf -v "$out_roles_json" '%s' "$roles_json"
}
