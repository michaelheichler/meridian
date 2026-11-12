#!/bin/bash

write_route_config() {
  jq '
    . + {
      schema_version: 1,
      routing: {
        active_profile: "balanced",
        profiles: {
          quality: {roles: {}},
          balanced: {roles: {}},
          turbo: {roles: {}}
        }
      }
    }
  ' "$CONFIG_DIR/settings.json" > "$PLANNING/config.json"
}

write_route_catalog() {
  local route_sha
  route_sha=$(shasum -a 256 "$ROUTE_BINARY" | awk '{print $1}')
  jq -n \
    --arg binary "$ROUTE_BINARY" \
    --arg sha "$route_sha" '
      {
        schema_version: 1,
        source: {
          binary_path: $binary,
          version: "fixture",
          sha256: $sha,
          detected_at: "2035-01-02T03:04:05Z"
        },
        models: [
          {selector: "nova-route", label: "Nova Route", description: "Fixture selector"},
          {selector: "ember-path", label: "Ember Path", description: "Second fixture selector"}
        ],
        reasoning: {
          scope: "global",
          accepted_values: ["deliberate", "swift", "default"],
          model_associations: {"nova-route": ["deliberate"]}
        }
      }
    ' > "$PLANNING/claude-capabilities.json"
}

routing_fixture_setup() {
  local temporary_root="${TMPDIR:-/tmp}"
  TEST_TEMP_DIR=$(mktemp -d "${temporary_root%/}/meridian-routing.XXXXXX")
  export TEST_TEMP_DIR
  export _ORIG_HOME="${HOME:-}"
  export _ORIG_MERIDIAN_PLANNING_DIR="${MERIDIAN_PLANNING_DIR:-}"
  export HOME="$TEST_TEMP_DIR"
  unset MERIDIAN_PLANNING_DIR CLAUDE_SESSION_ID 2>/dev/null || true
  PLANNING="$TEST_TEMP_DIR/.meridian"
  mkdir -p "$PLANNING"
  ROUTE_BINARY="$TEST_TEMP_DIR/claude-route-fixture"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "fixture"' > "$ROUTE_BINARY"
  chmod +x "$ROUTE_BINARY"
  write_route_config
  write_route_catalog
  reset_case_failures
}

routing_fixture_teardown() {
  if [ -n "${LOCK_OWNER_PID:-}" ]; then
    [ -z "${LOCK_OWNER_RELEASE:-}" ] || : > "$LOCK_OWNER_RELEASE"
    kill -TERM "$LOCK_OWNER_PID" 2>/dev/null || true
    wait "$LOCK_OWNER_PID" 2>/dev/null || true
  fi
  [ -z "${VAR_TEST_DIR:-}" ] || rm -rf "$VAR_TEST_DIR"
  teardown_temp_dir
}

config_digest() {
  shasum -a 256 "${1:-$PLANNING}/config.json" | awk '{print $1}'
}

snapshot_planning() {
  rm -rf "$TEST_TEMP_DIR/pristine"
  cp -R "$PLANNING" "$TEST_TEMP_DIR/pristine"
}

restore_planning() {
  rm -rf "$PLANNING"
  cp -R "$TEST_TEMP_DIR/pristine" "$PLANNING"
}

edit_json() {
  local file="$1"
  shift
  jq "$@" "$file" > "$file.next"
  mv "$file.next" "$file"
}

expect_jq() {
  local label="$1" file="$2" program="$3"
  jq -e "$program" "$file" >/dev/null \
    || record_case_failure "$label" "jq program did not hold for $file: $program"
}

wait_for_file() {
  local path="$1" attempt
  for ((attempt = 0; attempt < 500; attempt++)); do
    [ -e "$path" ] && return 0
    sleep 0.01
  done
  return 1
}

write_blocking_jq() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "$*" == *'"'"'.routing.profiles[$profile].roles[$role]'"'"'* ]] && [[ " $* " == *'"'"' --arg role docs '"'"'* ]]; then' \
    '  output=$("$REAL_JQ" "$@")' \
    '  : > "$ROUTING_BLOCK_READY"' \
    '  while [ ! -e "$ROUTING_BLOCK_RELEASE" ]; do sleep 0.01; done' \
    '  printf '"'"'%s\n'"'"' "$output"' \
    'else' \
    '  exec "$REAL_JQ" "$@"' \
    'fi' > "$1/jq"
}

write_marking_sleep() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[ -z "${ROUTING_SLEEP_MARK:-}" ] || : > "$ROUTING_SLEEP_MARK"' \
    'exec "$REAL_SLEEP" "$@"' > "$1/sleep"
}

install_blocking_jq() {
  local wrapper_dir="$TEST_TEMP_DIR/bin"
  mkdir -p "$wrapper_dir"
  write_blocking_jq "$wrapper_dir"
  write_marking_sleep "$wrapper_dir"
  chmod +x "$wrapper_dir/jq" "$wrapper_dir/sleep"
}

run_wrapped_routing() {
  local -a wrapper_env=(
    "PATH=$TEST_TEMP_DIR/bin:$PATH"
    "REAL_JQ=$(command -v jq)"
    "REAL_SLEEP=$(command -v sleep)"
    "ROUTING_BLOCK_READY=$TEST_TEMP_DIR/first-transform-ready"
    "ROUTING_BLOCK_RELEASE=$TEST_TEMP_DIR/release-first-transform"
  )
  exec env "${wrapper_env[@]}" "$@"
}

start_blocked_writer() {
  rm -f "$TEST_TEMP_DIR/first-transform-ready" "$TEST_TEMP_DIR/release-first-transform"
  run_wrapped_routing "$@" bash "$ROUTING" set "$PLANNING" balanced docs ember-path '"swift"' \
    >/dev/null 2>&1 &
  wait_for_file "$TEST_TEMP_DIR/first-transform-ready"
}
