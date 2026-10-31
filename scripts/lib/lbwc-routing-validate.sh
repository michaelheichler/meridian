validate_profile() {
  case "$1" in
    quality|balanced|turbo) ;;
    *) fail "unknown routing profile: $1" ;;
  esac
}

validate_role() {
  local role="$1"
  jq -e --arg role "$role" 'has($role)' "$ROLE_DEFAULTS_PATH" >/dev/null 2>&1 \
    || fail "unknown routing role: $role"
}

validate_config_file() {
  local config="$1"
  [ ! -L "$config" ] || fail "symbolic link paths are not allowed: $config"
  [ -f "$config" ] || fail "configuration is not readable: $config"
  jq -e 'type == "object"' "$config" >/dev/null 2>&1 || fail "configuration is not valid JSON: $config"
}

validate_routing_shape() {
  local config="$1"
  jq -e '
    (.routing.profiles | keys | sort) == ["balanced", "quality", "turbo"]
    and (.routing.active_profile | IN("quality", "balanced", "turbo"))
    and (all(.routing.profiles[]; .roles | type == "object"))
    and (all(.routing.profiles[].roles[];
      type == "object"
      and (keys | sort) == ["model", "reasoning", "status"]
      and (.model | type == "string" and length > 0)
      and ((.reasoning | type == "string" and length > 0) or .reasoning == null)
      and (.status | IN("resolved", "unresolved"))
    ))
  ' "$config" >/dev/null 2>&1 || fail 'routing profiles must be exactly quality, balanced, and turbo with valid cells'
}

validate_current_catalog() {
  local catalog="$1" binary expected actual
  bash "$SCRIPT_DIR/claude-capabilities.sh" validate "$catalog" >/dev/null
  binary=$(jq -r '.source.binary_path' "$catalog")
  expected=$(jq -r '.source.sha256' "$catalog")
  [ -f "$binary" ] && [ -x "$binary" ] || fail "catalog Claude Code binary is unavailable: $binary"
  actual=$(shasum -a 256 "$binary" | awk '{print $1}') || fail 'could not fingerprint Claude Code executable'
  [ "$actual" = "$expected" ] || fail 'Claude Code binary fingerprint differs from the saved capability catalog'
}

validate_route_value() {
  local catalog="$1" selector="$2" reasoning_json="$3"
  jq -e --arg selector "$selector" '[.models[].selector] | index($selector) != null' "$catalog" >/dev/null \
    || fail "model selector is not present in the saved capability catalog: $selector"
  jq -e 'type == "string" or . == null' <<< "$reasoning_json" >/dev/null 2>&1 \
    || fail 'reasoning must be a detected string or null'
  if jq -e '. != null' <<< "$reasoning_json" >/dev/null; then
    jq -e --argjson reasoning "$reasoning_json" '.reasoning.accepted_values | index($reasoning) != null' "$catalog" >/dev/null \
      || fail "reasoning value is not present in the saved capability catalog: $(jq -r . <<< "$reasoning_json")"
    jq -e --arg selector "$selector" --argjson reasoning "$reasoning_json" '
      if .reasoning.scope == "global"
      then true
      else
        (.reasoning.model_associations[$selector] // null) as $allowed
        | $allowed == null or ($allowed | index($reasoning) != null)
      end
    ' "$catalog" >/dev/null || fail "reasoning value is not accepted for model selector: $selector"
  fi
}

validate_profile_routes() {
  local catalog="$1" config="$2" profile="$3" role model reasoning status
  while IFS=$'\t' read -r role model reasoning status; do
    [ -n "$role" ] || continue
    validate_role "$role"
    [ "$status" = "resolved" ] || fail "unresolved routing cell: $profile/$role"
    validate_route_value "$catalog" "$model" "$reasoning"
  done < <(jq -r --arg profile "$profile" '
    .routing.profiles[$profile].roles
    | to_entries[]
    | [.key, .value.model, (.value.reasoning | tojson), .value.status]
    | @tsv
  ' "$config")
}

validate_routing_config() {
  local planning_dir="$1" catalog config profile active
  catalog="$planning_dir/claude-capabilities.json"
  config="$planning_dir/config.json"
  validate_current_catalog "$catalog"
  validate_config_file "$config"
  validate_routing_shape "$config"
  active=$(jq -r '.routing.active_profile // empty' "$config")
  validate_profile "$active"
  for profile in quality balanced turbo; do
    jq -e --arg profile "$profile" '.routing.profiles[$profile].roles | type == "object"' "$config" >/dev/null 2>&1 \
      || fail "routing profile roles must be an object: $profile"
    validate_profile_routes "$catalog" "$config" "$profile"
  done
  printf '%s\n' "$config"
}
