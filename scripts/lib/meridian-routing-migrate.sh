validate_legacy_roles() {
  local config="$1" role
  while IFS= read -r role; do
    [ -n "$role" ] || continue
    validate_role "$role"
  done < <(jq -r '(.roles // {}) | if type == "object" then keys[] else empty end' "$config")
}

assert_migration_profile() {
  local planning_dir="$1" config="$2" profile profile_json
  profile=$(jq -r '(.routing.active_profile // .model_profile // "balanced") | if . == "budget" then "turbo" else . end' "$config") \
    || fail 'could not resolve migrated routing profile'
  validate_profile "$profile"
  profile_json=$(jq -cn --arg profile "$profile" '$profile') || fail 'could not encode routing profile'
  bash "$SCRIPT_DIR/meridian-config.sh" assert-execution-setting-writable \
    "$planning_dir" routing.active_profile "$profile_json"
}

migrate_filter_cells() {
  cat <<'JQ'
def normalized_profile($value): if $value == "budget" then "turbo" else $value end;
def normalized_cell($cell):
  ($cell.model // null) as $model
  | (if $cell | has("reasoning") then $cell.reasoning else ($cell.effort // null) end) as $reasoning
  | ($catalog[0]) as $capabilities
  | ($capabilities.models | map(.selector) | index($model) != null) as $known_model
  | ($reasoning == null or ($capabilities.reasoning.accepted_values | index($reasoning) != null)) as $known_reasoning
  | ($capabilities.reasoning.model_associations[$model] // null) as $association
  | ($reasoning == null
      or $capabilities.reasoning.scope == "global"
      or $association == null
      or ($association | index($reasoning) != null)) as $allowed_reasoning
  | {model: $model, reasoning: $reasoning, status: (if $known_model and $known_reasoning and $allowed_reasoning then "resolved" else "unresolved" end)};
JQ
}

migrate_filter_profiles() {
  cat <<'JQ'
(.routing.profiles // {}) as $existing_profiles
| (($existing_profiles.budget.roles // {}) * ($existing_profiles.turbo.roles // {})) as $turbo_roles
| .routing.profiles = {
    quality: {roles: ($existing_profiles.quality.roles // {})},
    balanced: {roles: ($existing_profiles.balanced.roles // {})},
    turbo: {roles: $turbo_roles}
  }
| .routing.active_profile = normalized_profile(.routing.active_profile // .model_profile // "balanced")
| .routing.profiles |= with_entries(.value.roles |= with_entries(.value |= normalized_cell(.)))
| .routing.active_profile as $active
| ((.roles // {}) | with_entries(
    select(.value | has("model") or has("effort") or has("reasoning"))
    | .value = normalized_cell({
        model: .value.model,
        reasoning: (if .value | has("reasoning") then .value.reasoning else (.value.effort // null) end)
      })
  )) as $legacy_roles
| .routing.profiles[$active].roles = ($legacy_roles * .routing.profiles[$active].roles)
| if (.roles | type) == "object"
  then .roles |= with_entries(.value |= del(.model, .effort, .reasoning))
  else .
  end
| del(.model_profile)
JQ
}

migrate_routes() {
  local planning_dir="$1" catalog config migrated
  catalog="$planning_dir/claude-capabilities.json"
  config="$planning_dir/config.json"
  acquire_config_lock "$planning_dir"
  validate_current_catalog "$catalog"
  validate_config_file "$config"
  validate_legacy_roles "$config"
  assert_migration_profile "$planning_dir" "$config"
  migrated=$(jq -c --slurpfile catalog "$catalog" "$(migrate_filter_cells)
$(migrate_filter_profiles)" "$config") || fail 'could not migrate routing configuration'
  atomic_write_config "$planning_dir" "$migrated"
}
