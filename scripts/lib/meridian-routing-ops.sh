atomic_write_config() {
  local planning_dir="$1" value="$2" temporary
  if [ "$LOCK_DIR" != "$planning_dir/.routing.lock" ] || [ ! -d "$LOCK_DIR" ] \
    || [ -z "$LOCK_OWNER_RECORD" ] || ! lock_is_owned; then
    fail 'routing configuration write requires the routing lock'
  fi
  temporary=$(mktemp "$planning_dir/.config.json.routing.XXXXXX") || fail 'could not create routing configuration temporary file'
  printf '%s\n' "$value" > "$temporary" || {
    rm -f "$temporary"
    fail 'could not write routing configuration temporary file'
  }
  validate_routing_shape "$temporary"
  lock_is_owned || {
    rm -f "$temporary"
    fail 'routing configuration write requires the routing lock'
  }
  mv -f "$temporary" "$planning_dir/config.json" || {
    rm -f "$temporary"
    fail 'could not atomically persist routing configuration'
  }
  printf '%s\n' "$planning_dir/config.json"
}

atomic_set_route() {
  local planning_dir="$1" profile="$2" role="$3" selector="$4" reasoning_json="$5"
  local catalog config updated
  [ -n "$role" ] || fail 'routing role must not be empty'
  validate_profile "$profile"
  validate_role "$role"
  catalog="$planning_dir/claude-capabilities.json"
  config="$planning_dir/config.json"
  acquire_config_lock "$planning_dir"
  validate_config_file "$config"
  validate_routing_shape "$config"
  validate_current_catalog "$catalog"
  validate_route_value "$catalog" "$selector" "$reasoning_json"
  updated=$(jq -c \
    --arg profile "$profile" \
    --arg role "$role" \
    --arg model "$selector" \
    --argjson reasoning "$reasoning_json" '
      .routing.profiles[$profile].roles[$role] = {
        model: $model,
        reasoning: $reasoning,
        status: "resolved"
      }
    ' "$config") || fail 'could not update routing configuration'
  atomic_write_config "$planning_dir" "$updated"
}

copy_profile() {
  local planning_dir="$1" source="$2" destination="$3" catalog config updated
  validate_profile "$source"
  validate_profile "$destination"
  catalog="$planning_dir/claude-capabilities.json"
  config="$planning_dir/config.json"
  acquire_config_lock "$planning_dir"
  validate_current_catalog "$catalog"
  validate_config_file "$config"
  validate_routing_shape "$config"
  validate_profile_routes "$catalog" "$config" "$source"
  updated=$(jq -c --arg source "$source" --arg destination "$destination" '
    .routing.profiles[$destination].roles = .routing.profiles[$source].roles
  ' "$config") || fail 'could not copy routing profile'
  atomic_write_config "$planning_dir" "$updated"
}

activate_profile() {
  local planning_dir="$1" profile="$2" catalog config updated profile_json
  validate_profile "$profile"
  catalog="$planning_dir/claude-capabilities.json"
  config="$planning_dir/config.json"
  acquire_config_lock "$planning_dir"
  validate_current_catalog "$catalog"
  validate_config_file "$config"
  validate_routing_shape "$config"
  profile_json=$(jq -cn --arg profile "$profile" '$profile') || fail 'could not encode routing profile'
  bash "$SCRIPT_DIR/meridian-config.sh" assert-execution-setting-writable \
    "$planning_dir" routing.active_profile "$profile_json"
  updated=$(jq -c --arg profile "$profile" '.routing.active_profile = $profile' "$config") \
    || fail 'could not activate routing profile'
  atomic_write_config "$planning_dir" "$updated"
}

resolve_route() {
  local planning_dir="$1" role="$2" requested_profile="${3:-}" catalog config profile cell model reasoning
  catalog="$planning_dir/claude-capabilities.json"
  config="$planning_dir/config.json"
  validate_current_catalog "$catalog"
  validate_config_file "$config"
  validate_routing_shape "$config"
  validate_role "$role"
  if [ -n "$requested_profile" ]; then
    profile="$requested_profile"
  else
    profile=$(jq -r '.routing.active_profile // empty' "$config")
  fi
  validate_profile "$profile"
  cell=$(jq -c --arg profile "$profile" --arg role "$role" '.routing.profiles[$profile].roles[$role] // null' "$config")
  jq -e 'type == "object" and .status == "resolved" and (.model | type == "string") and has("reasoning")' <<< "$cell" >/dev/null \
    || fail "route is unresolved or absent for profile '$profile' and role '$role'"
  model=$(jq -r '.model' <<< "$cell")
  reasoning=$(jq -c '.reasoning' <<< "$cell")
  validate_route_value "$catalog" "$model" "$reasoning"
  jq -cS -n --arg model "$model" --arg profile "$profile" --argjson reasoning "$reasoning" --arg role "$role" \
    '{model:$model,profile:$profile,reasoning:$reasoning,role:$role}'
}

check_route_value() {
  local planning_dir="$1" selector="$2" reasoning_json="$3" catalog
  catalog="$planning_dir/claude-capabilities.json"
  validate_current_catalog "$catalog"
  validate_route_value "$catalog" "$selector" "$reasoning_json"
  jq -cS -n --arg model "$selector" --argjson reasoning "$reasoning_json" '{model:$model,reasoning:$reasoning}'
}
