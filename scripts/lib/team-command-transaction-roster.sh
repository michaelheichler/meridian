check_roster_critic() {
  local seen_critic="$1" configured_critic
  configured_critic=$(jq -r --arg role "$ROSTER_ENGINEER" '.[$role].pairsWith // empty' "$ROLE_DEFAULTS_PATH")
  if [ "$seen_critic" = true ]; then
    [ -n "$configured_critic" ] || fail "role '$ROSTER_ENGINEER' has no configured critic"
    [ "$ROSTER_CRITIC" = "$configured_critic" ] \
      || fail "critic '$ROSTER_CRITIC' is not the configured pair for '$ROSTER_ENGINEER' ($configured_critic)"
  else
    [ -n "$configured_critic" ] || fail "role '$ROSTER_ENGINEER' has no configured pair; pass its critic explicitly"
    ROSTER_CRITIC="$configured_critic"
  fi
}

resolve_roster_from_roles() {
  local role seen_critic=false seen_testdev=false engineer_count=0
  for role in "${ROLES[@]}"; do
    is_valid_role "$role" || fail "invalid role: $role"
    if [ "$role" = "test-dev" ]; then
      [ "$seen_testdev" = false ] || fail 'duplicate role: test-dev'
      seen_testdev=true
    elif is_critic_role "$role"; then
      [ "$seen_critic" = false ] || fail 'roster accepts at most one critic'
      seen_critic=true
      ROSTER_CRITIC="$role"
    else
      engineer_count=$((engineer_count + 1))
      [ "$engineer_count" -eq 1 ] || fail 'roster accepts exactly one engineer role'
      ROSTER_ENGINEER="$role"
    fi
  done
  [ -n "$ROSTER_ENGINEER" ] || fail 'roster requires one engineer role'
  ROSTER_TEST_DEV="$seen_testdev"
  check_roster_critic "$seen_critic"
}

resolve_roster_from_defaults() {
  local configured_critic
  ROSTER_ENGINEER="${ENGINEER_ARG:-web-engineer}"
  is_valid_role "$ROSTER_ENGINEER" || fail "invalid engineer role: $ROSTER_ENGINEER"
  configured_critic=$(jq -r --arg role "$ROSTER_ENGINEER" '.[$role].pairsWith // empty' "$ROLE_DEFAULTS_PATH")
  [ -n "$configured_critic" ] || fail "engineer role '$ROSTER_ENGINEER' has no configured critic"
  ROSTER_CRITIC="$configured_critic"
  ROSTER_TEST_DEV="$WANT_TEST_DEV"
}

resolve_roster() {
  ROSTER_ENGINEER=""
  ROSTER_CRITIC=""
  ROSTER_TEST_DEV=false
  if [ "${#ROLES[@]}" -gt 0 ]; then
    resolve_roster_from_roles
  else
    resolve_roster_from_defaults
  fi
  if [ "$ROSTER_TEST_DEV" = true ]; then
    jq -e --arg role "$ROSTER_ENGINEER" '.trios[$role] != null' "$ROLE_DEFAULTS_PATH" >/dev/null \
      || fail "role '$ROSTER_ENGINEER' has no configured trio for test-dev"
    TEAM_MODE="trio"
  else
    TEAM_MODE="pair"
  fi
  ROSTER_ROLES_JSON=$(jq -cn \
    --arg engineer "$ROSTER_ENGINEER" --arg critic "$ROSTER_CRITIC" --argjson test_dev "$ROSTER_TEST_DEV" \
    '[$engineer, $critic] + (if $test_dev then ["test-dev"] else [] end)')
}
