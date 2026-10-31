emit_result() {
  local human="$1" json="$2"
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    printf '%s\n' "$json"
  else
    printf '%s\n' "$human"
  fi
}

escape_cell() {
  local value="$1"
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  value=${value//$'\t'/ }
  value=$(printf '%s' "$value" | LC_ALL=C tr '\000-\010\013\014\016-\037\177' '?')
  value=${value//\\/\\\\}
  value=${value//|/\\|}
  printf '%s' "$value"
}

show_json() {
  local planning_dir="$1" catalog config
  catalog="$planning_dir/claude-capabilities.json"
  config="$planning_dir/config.json"
  jq -cS \
    --slurpfile catalog "$catalog" \
    --slurpfile defaults "$ROLE_DEFAULTS" '
      def roles:
        $defaults[0]
        | to_entries
        | map(select(.value | type == "object" and has("description")))
        | map(.key);
      .routing as $routing
      | {
          schema_version: 1,
          active_profile: $routing.active_profile,
          structural_default: null,
          models: $catalog[0].models,
          reasoning: $catalog[0].reasoning,
          profiles: (reduce ["quality", "balanced", "turbo"][] as $profile ({};
            .[$profile] = {
              roles: (reduce roles[] as $role ({};
                .[$role] = ($routing.profiles[$profile].roles[$role] // null)
              ))
            }
          ))
        }
    ' "$config"
}

print_models() {
  local catalog="$1" selector label description
  printf '%s\n' 'Detected models'
  printf '%s\n' '| Selector | Label | Description |' '| --- | --- | --- |'
  while IFS= read -r -d '' selector \
    && IFS= read -r -d '' label \
    && IFS= read -r -d '' description; do
    [ -n "$label" ] || label='Label unavailable'
    [ -n "$description" ] || description='Description unavailable'
    printf '| %s | %s | %s |\n' \
      "$(escape_cell "$selector")" \
      "$(escape_cell "$label")" \
      "$(escape_cell "$description")"
  done < <(jq -j '.models[] | .selector, "\u0000", (.label // ""), "\u0000", (.description // ""), "\u0000"' "$catalog")
}

print_reasoning() {
  local catalog="$1" value
  printf '\n%s\n' 'Detected reasoning'
  printf '%s\n' '| Stored value | Meaning |' '| --- | --- |'
  printf '%s\n' '| null | Claude Code default |'
  while IFS= read -r -d '' value; do
    printf '| %s | Detected value |\n' "$(escape_cell "$value")"
  done < <(jq -j '.reasoning.accepted_values[] | ., "\u0000"' "$catalog")
}

print_profiles() {
  local snapshot="$1" profile role model reasoning status
  printf '\n%s\n' 'Routing profiles'
  printf '%s\n' '| Profile | Role | Model | Reasoning | Status |' '| --- | --- | --- | --- | --- |'
  while IFS= read -r -d '' profile \
    && IFS= read -r -d '' role \
    && IFS= read -r -d '' model \
    && IFS= read -r -d '' reasoning \
    && IFS= read -r -d '' status; do
    printf '| %s | %s | %s | %s | %s |\n' \
      "$(escape_cell "$profile")" \
      "$(escape_cell "$role")" \
      "$(escape_cell "$model")" \
      "$(escape_cell "$reasoning")" \
      "$(escape_cell "$status")"
  done < <(jq -j '
    .profiles
    | to_entries[]
    | .key as $profile
    | .value.roles
    | to_entries[]
    | .key as $role
    | .value as $cell
    | $profile, "\u0000",
      $role, "\u0000",
      (if $cell == null then "Not configured" else $cell.model end), "\u0000",
      (if $cell == null then "Not configured" elif $cell.reasoning == null then "Claude Code default" else $cell.reasoning end), "\u0000",
      (if $cell == null then "Not configured" else $cell.status end), "\u0000"
  ' <<< "$snapshot")
}
