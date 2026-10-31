validate_config_json() {
  local value="$1" roles
  roles=$(allowed_role_names)
  jq -e --argjson roles "$roles" -f "$SCRIPT_DIR/lib/lbwc-config-validate.jq" <<< "$value" >/dev/null 2>&1
}

validate_or_fail() {
  local value="$1"
  validate_config_json "$value" || fail 'invalid configuration'
}

validate_tmux_execution_json() {
  local tmux_execution default_config config
  tmux_execution=$(cat)
  jq -e 'type == "object"' <<< "$tmux_execution" >/dev/null 2>&1 \
    || fail 'invalid tmux execution configuration'
  default_config=$(migrate_config_json '{}') || fail 'could not build default configuration'
  config=$(jq -cn --argjson defaults "$default_config" --argjson tmux_execution "$tmux_execution" \
    '$defaults | .tmux_execution = $tmux_execution') \
    || fail 'could not build tmux execution validation configuration'
  validate_config_json "$config" || fail 'invalid tmux execution configuration'
  printf '%s\n' "$tmux_execution"
}

initialize_config() {
  local planning_dir="$1" path reported_path existing migrated
  read_defaults >/dev/null
  assert_no_symbolic_links "$planning_dir"
  mkdir -p "$planning_dir" || fail "could not create planning directory: $planning_dir"
  assert_no_symbolic_links "$planning_dir"
  reported_path=$(config_path "$planning_dir")
  enter_planning_dir "$planning_dir"
  acquire_lock
  path="config.json"
  assert_no_symbolic_links "$path"
  existing=$(read_existing_config "$path")
  assert_supported_config_version "$existing"
  migrated=$(migrate_config_json "$existing") || fail 'could not migrate configuration'
  validate_or_fail "$migrated"
  atomic_write "$path" "$migrated"
  printf '%s\n' "$reported_path"
}

validate_config_file() {
  local planning_dir="$1" path value
  path=$(config_path "$planning_dir")
  [ -f "$path" ] || fail "configuration is not readable: $path"
  value=$(read_existing_config "$path")
  validate_or_fail "$value"
  printf '%s\n' "$path"
}

get_setting() {
  local planning_dir="$1" setting="$2" path value
  path=$(config_path "$planning_dir")
  value=$(read_existing_config "$path")
  validate_or_fail "$value"
  jq -e --arg setting "$setting" 'getpath($setting | split(".")) != null' <<< "$value" >/dev/null || fail "unknown setting: $setting"
  jq --arg setting "$setting" 'getpath($setting | split("."))' <<< "$value"
}

set_setting() {
  local planning_dir="$1" setting="$2" literal="$3" path reported_path planning_root existing updated
  setting_is_writable "$setting" || fail "setting is not writable: $setting"
  jq -e 'type' <<< "$literal" >/dev/null 2>&1 || fail 'setting value is not valid JSON'
  assert_no_symbolic_links "$planning_dir"
  [ -d "$planning_dir" ] || fail "planning directory does not exist: $planning_dir"
  reported_path=$(config_path "$planning_dir")
  enter_planning_dir "$planning_dir"
  planning_root=$(pwd -P)
  acquire_lock
  path="config.json"
  existing=$(read_existing_config "$path")
  validate_or_fail "$existing"
  assert_execution_setting_is_writable "$planning_root" "$setting" "$literal"
  updated=$(jq -c --arg setting "$setting" --argjson value "$literal" 'setpath($setting | split("."); $value)' <<< "$existing") || fail 'could not update configuration'
  validate_or_fail "$updated"
  atomic_write "$path" "$updated"
  printf '%s\n' "$reported_path"
}
