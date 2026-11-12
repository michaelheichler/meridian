parity_defaults_json() {
  cat "$SCRIPT_DIR/lib/meridian-config-parity.json"
}

read_defaults() {
  local base parity
  [ -f "$DEFAULTS_PATH" ] || fail "default configuration is not readable: $DEFAULTS_PATH"
  base=$(cat "$DEFAULTS_PATH")
  jq -e 'type == "object"' <<< "$base" >/dev/null 2>&1 \
    || fail "default configuration is not valid JSON: $DEFAULTS_PATH"
  parity=$(parity_defaults_json)
  jq -cn --argjson base "$base" --argjson parity "$parity" '$base * $parity' \
    || fail 'could not build default configuration'
}

allowed_role_names() {
  [ -f "$ROLE_DEFAULTS_PATH" ] || fail "role defaults are not readable: $ROLE_DEFAULTS_PATH"
  jq -ce '[keys[] | select(. != "oracles" and . != "trios")]' "$ROLE_DEFAULTS_PATH" \
    || fail "role defaults are not valid JSON: $ROLE_DEFAULTS_PATH"
}

assert_supported_config_version() {
  local value="$1"
  jq -e 'if has("schema_version") then .schema_version == 1 else true end' <<< "$value" >/dev/null 2>&1 || fail 'unsupported configuration version'
}

migrate_config_json() {
  local existing="$1" defaults
  defaults=$(read_defaults)
  jq -cn --argjson defaults "$defaults" --argjson existing "$existing" \
    -f "$SCRIPT_DIR/lib/meridian-config-migrate.jq"
}
