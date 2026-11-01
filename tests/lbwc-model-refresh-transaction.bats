#!/usr/bin/env bats

load test_helper
load model_cli_helper

setup() {
  setup_model_sandbox
  REAL_CP=$(command -v cp)
  REAL_MV=$(command -v mv)
  REAL_BASH=$(command -v bash)
}

teardown() {
  teardown_model_sandbox
}

make_traced_cli() {
  local fixture_root="$TEST_ROOT/traced-plugin"
  mkdir -p "$fixture_root/scripts" "$fixture_root/templates/agent-roles"
  copy_script_with_libs "$SCRIPT" "$fixture_root/scripts/lbwc-model"
  cp "$REPO_ROOT/templates/agent-roles/defaults.json" "$fixture_root/templates/agent-roles/defaults.json"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "capabilities:%s:%s\\n" "$1" "$2" >> "$LBWC_MODEL_TRACE"' \
    'exec "$REAL_CAPABILITIES" "$@"' > "$fixture_root/scripts/claude-capabilities.sh"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "routing:%s:%s\\n" "$1" "$2" >> "$LBWC_MODEL_TRACE"' \
    'exec "$REAL_ROUTING" "$@"' > "$fixture_root/scripts/lbwc-routing.sh"
  chmod +x "$fixture_root/scripts/"*
  printf '%s\n' "$fixture_root/scripts/lbwc-model"
}

assert_state_unchanged() {
  [ "$1" = "$(config_sha)" ] || { echo "config.json changed" >&2; return 1; }
  [ "$2" = "$(catalog_sha)" ] || { echo "claude-capabilities.json changed" >&2; return 1; }
}

tool_path() {
  case "$1" in
    model) printf '%s\n' "$SCRIPT" ;;
    config) printf '%s\n' "$REPO_ROOT/scripts/lbwc-config.sh" ;;
    routing) printf '%s\n' "$REPO_ROOT/scripts/lbwc-routing.sh" ;;
    capabilities) printf '%s\n' "$REPO_ROOT/scripts/claude-capabilities.sh" ;;
  esac
}

@test "refresh invokes capability generation before route migration and validation" {
  local traced_cli trace="$TEST_ROOT/refresh-trace"
  traced_cli=$(make_traced_cli)

  run env \
    LBWC_MODEL_TRACE="$trace" \
    REAL_CAPABILITIES="$REPO_ROOT/scripts/claude-capabilities.sh" \
    REAL_ROUTING="$REPO_ROOT/scripts/lbwc-routing.sh" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$traced_cli" --json refresh "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$trace")" = "routing:transaction:$PLANNING_DIR" ]
  [ "$(sed -n '2p' "$trace")" = "routing:assert-transaction:$PLANNING_DIR" ]
  [[ "$(sed -n '3p' "$trace")" == capabilities:refresh:*'/.lbwc-planning' ]]
  [[ "$(sed -n '4p' "$trace")" == routing:migrate:*'/.lbwc-planning' ]]
  [[ "$(sed -n '5p' "$trace")" == routing:validate:*'/.lbwc-planning' ]]
  [ "$(sed -n '6p' "$trace")" = "routing:validate:$(physical_planning_dir)" ]
  [ "$(wc -l < "$trace" | tr -d ' ')" -eq 6 ]
  [ "$output" = '{"operation":"refresh","status":"ok"}' ]
}

@test "refresh preserves a concurrent trusted configuration update" {
  local ready="$TEST_ROOT/refresh-read-ready" release="$TEST_ROOT/refresh-read-release"
  local config_ready="$TEST_ROOT/config-setter-ready"
  local refresh_output="$TEST_ROOT/refresh-output" config_output="$TEST_ROOT/config-output"
  local refresh_pid config_pid refresh_status=0 config_status=0
  bash "$REPO_ROOT/scripts/lbwc-config.sh" init "$PLANNING_DIR" >/dev/null
  install_shim "$TEST_ROOT/race-bin" cp <<'SHIM'
source_path=${1:-}
destination=${2:-}
"$REAL_CP" "$@"
if [[ "$source_path" == */.lbwc-model-refresh.pending/config.after ]] &&
  [[ "$destination" == "$MODEL_RACE_CONFIG".model-refresh.* ]]; then
  : > "$MODEL_RACE_READY"
  while [ ! -e "$MODEL_RACE_RELEASE" ]; do sleep 0.01; done
fi
SHIM
  install_shim "$TEST_ROOT/config-race-bin" bash "$REAL_BASH" <<'SHIM'
if [ "${1:-}" = "$MODEL_RACE_ROUTING" ] && [ "${2:-}" = transaction ]; then
  : > "$MODEL_CONFIG_SETTER_READY"
fi
exec "$REAL_BASH" "$@"
SHIM

  env \
    PATH="$TEST_ROOT/race-bin:$PATH" \
    REAL_CP="$REAL_CP" \
    MODEL_RACE_CONFIG="$(physical_planning_dir)/.config.json" \
    MODEL_RACE_READY="$ready" \
    MODEL_RACE_RELEASE="$release" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$SCRIPT" refresh "$PLANNING_DIR" > "$refresh_output" 2>&1 &
  refresh_pid=$!
  wait_for_path "$ready" || { cat "$refresh_output" >&3; return 1; }

  env \
    PATH="$TEST_ROOT/config-race-bin:$PATH" \
    REAL_BASH="$REAL_BASH" \
    MODEL_RACE_ROUTING="$REPO_ROOT/scripts/lbwc-routing.sh" \
    MODEL_CONFIG_SETTER_READY="$config_ready" \
    "$REAL_BASH" "$REPO_ROOT/scripts/lbwc-config.sh" set "$PLANNING_DIR" effort '"turbo"' \
    > "$config_output" 2>&1 &
  config_pid=$!
  wait_for_path "$config_ready"
  : > "$release"
  wait "$refresh_pid" || refresh_status=$?
  wait "$config_pid" || config_status=$?

  [ "$refresh_status" -eq 0 ]
  [ "$config_status" -eq 0 ]
  jq -e '.effort == "turbo"' "$PLANNING_DIR/config.json" >/dev/null
}

@test "refresh restores both files when the second commit rename fails" {
  local config_before catalog_before
  catalog_before=$(catalog_sha)
  config_before=$(config_sha)
  install_shim "$TEST_ROOT/commit-failure-bin" mv <<'SHIM'
destination=${!#}
if [ "$destination" = "$MODEL_COMMIT_CONFIG" ] && [ ! -e "$MODEL_COMMIT_FAIL_MARKER" ]; then
  : > "$MODEL_COMMIT_FAIL_MARKER"
  exit 73
fi
exec "$REAL_MV" "$@"
SHIM

  run env \
    PATH="$TEST_ROOT/commit-failure-bin:$PATH" \
    REAL_MV="$REAL_MV" \
    MODEL_COMMIT_CONFIG="$(physical_planning_dir)/config.json" \
    MODEL_COMMIT_FAIL_MARKER="$TEST_ROOT/commit-mv-failed" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -ne 0 ]
  assert_state_unchanged "$config_before" "$catalog_before"
  [ ! -e "$PLANNING_DIR/.lbwc-model-refresh.pending" ]
}

@test "refresh restores both files after a catchable interruption" {
  local config_before catalog_before refresh_pid refresh_status=0
  local ready="$TEST_ROOT/interrupt-ready" release="$TEST_ROOT/interrupt-release" child_pid_path="$TEST_ROOT/interrupt-child-pid"
  catalog_before=$(catalog_sha)
  config_before=$(config_sha)
  install_shim "$TEST_ROOT/interrupt-bin" cp <<'SHIM'
source_path=${1:-}
destination=${2:-}
"$REAL_CP" "$@"
if [[ "$source_path" == */.lbwc-model-refresh.pending/config.after ]] &&
  [[ "$destination" == "$MODEL_INTERRUPT_PREFIX".model-refresh.* ]]; then
  printf '%s\n' "$PPID" > "$MODEL_INTERRUPT_CHILD_PID"
  : > "$MODEL_INTERRUPT_READY"
  while [ ! -e "$MODEL_INTERRUPT_RELEASE" ]; do sleep 0.01; done
fi
SHIM

  env \
    PATH="$TEST_ROOT/interrupt-bin:$PATH" \
    REAL_CP="$REAL_CP" \
    MODEL_INTERRUPT_PREFIX="$(physical_planning_dir)/.config.json" \
    MODEL_INTERRUPT_CHILD_PID="$child_pid_path" \
    MODEL_INTERRUPT_READY="$ready" \
    MODEL_INTERRUPT_RELEASE="$release" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$SCRIPT" refresh "$PLANNING_DIR" >/dev/null 2>&1 &
  refresh_pid=$!
  wait_for_path "$ready"
  kill -TERM "$(<"$child_pid_path")"
  : > "$release"
  wait "$refresh_pid" || refresh_status=$?

  [ "$refresh_status" -ne 0 ]
  assert_state_unchanged "$config_before" "$catalog_before"
  [ ! -e "$PLANNING_DIR/.lbwc-model-refresh.pending" ]
  [ ! -e "$PLANNING_DIR/.routing.lock" ]
}

@test "refresh rejects a swapped published journal directory without changing either state file" {
  local config_before catalog_before external_sha marker="$TEST_ROOT/journal-directory-swapped"
  local attacker="$TEST_ROOT/attacker-journal" external_catalog="$TEST_ROOT/external-catalog"
  local pending
  pending="$(physical_planning_dir)/.lbwc-model-refresh.pending"
  mkdir -p "$attacker"
  cp "$PLANNING_DIR/config.json" "$attacker/config.before"
  jq '.effort = "turbo"' "$PLANNING_DIR/config.json" > "$attacker/config.after"
  cp "$CATALOG" "$attacker/catalog.before"
  cp "$CATALOG" "$external_catalog"
  ln -s "$external_catalog" "$attacker/catalog.after"
  : > "$attacker/catalog.was-present"
  external_sha=$(file_sha_of "$external_catalog")
  install_shim "$TEST_ROOT/journal-directory-swap-bin" cp <<'SHIM'
source_path=${1:-}
destination=${2:-}
if [[ "$source_path" == "$MODEL_SWAP_PENDING/config.after" ]] &&
  [[ "$destination" == "$MODEL_SWAP_CONFIG".model-refresh.* ]] &&
  [ ! -e "$MODEL_SWAP_MARKER" ]; then
  "$REAL_MV" "$MODEL_SWAP_PENDING" "$MODEL_SWAP_ORIGINAL"
  "$REAL_MV" "$MODEL_SWAP_ATTACKER" "$MODEL_SWAP_PENDING"
  : > "$MODEL_SWAP_MARKER"
fi
exec "$REAL_CP" "$@"
SHIM
  catalog_before=$(catalog_sha)
  config_before=$(config_sha)

  run env \
    PATH="$TEST_ROOT/journal-directory-swap-bin:$PATH" \
    REAL_CP="$REAL_CP" \
    REAL_MV="$REAL_MV" \
    MODEL_SWAP_PENDING="$pending" \
    MODEL_SWAP_ORIGINAL="$TEST_ROOT/original-journal" \
    MODEL_SWAP_ATTACKER="$attacker" \
    MODEL_SWAP_CONFIG="$(physical_planning_dir)/.config.json" \
    MODEL_SWAP_MARKER="$marker" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ -e "$marker" ]
  [ "$status" -ne 0 ]
  assert_state_unchanged "$config_before" "$catalog_before"
  [ "$external_sha" = "$(file_sha_of "$external_catalog")" ]
  [ -e "$PLANNING_DIR/.lbwc-model-refresh.pending" ]
}

@test "refresh rejects a symlink swapped onto the published journal boundary" {
  local config_before catalog_before attacker_sha marker="$TEST_ROOT/journal-symlink-swapped"
  local attacker="$TEST_ROOT/external-journal" pending real_ln
  pending="$(physical_planning_dir)/.lbwc-model-refresh.pending"
  real_ln=$(command -v ln)
  mkdir -p "$attacker"
  cp "$PLANNING_DIR/config.json" "$attacker/config.before"
  jq '.effort = "turbo"' "$PLANNING_DIR/config.json" > "$attacker/config.after"
  cp "$CATALOG" "$attacker/catalog.before"
  cp "$CATALOG" "$attacker/catalog.after"
  : > "$attacker/catalog.was-present"
  attacker_sha=$(file_sha_of "$attacker/config.after")
  install_shim "$TEST_ROOT/journal-symlink-swap-bin" cp <<'SHIM'
source_path=${1:-}
destination=${2:-}
if [[ "$source_path" == "$MODEL_SWAP_PENDING/config.after" ]] &&
  [[ "$destination" == "$MODEL_SWAP_CONFIG".model-refresh.* ]] &&
  [ ! -e "$MODEL_SWAP_MARKER" ]; then
  "$REAL_MV" "$MODEL_SWAP_PENDING" "$MODEL_SWAP_ORIGINAL"
  "$REAL_LN" -s "$MODEL_SWAP_ATTACKER" "$MODEL_SWAP_PENDING"
  : > "$MODEL_SWAP_MARKER"
fi
exec "$REAL_CP" "$@"
SHIM
  catalog_before=$(catalog_sha)
  config_before=$(config_sha)

  run env \
    PATH="$TEST_ROOT/journal-symlink-swap-bin:$PATH" \
    REAL_CP="$REAL_CP" \
    REAL_LN="$real_ln" \
    REAL_MV="$REAL_MV" \
    MODEL_SWAP_PENDING="$pending" \
    MODEL_SWAP_ORIGINAL="$TEST_ROOT/original-symlink-journal" \
    MODEL_SWAP_ATTACKER="$attacker" \
    MODEL_SWAP_CONFIG="$(physical_planning_dir)/.config.json" \
    MODEL_SWAP_MARKER="$marker" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -ne 0 ]
  [ -e "$marker" ]
  [ -L "$PLANNING_DIR/.lbwc-model-refresh.pending" ]
  assert_state_unchanged "$config_before" "$catalog_before"
  [ "$attacker_sha" = "$(file_sha_of "$attacker/config.after")" ]
}

@test "refresh rejects a swapped after image without changing either state file" {
  local config_before catalog_before external_sha marker="$TEST_ROOT/journal-after-swapped"
  local external_config="$TEST_ROOT/external-config-after" pending
  pending="$(physical_planning_dir)/.lbwc-model-refresh.pending"
  jq '.effort = "turbo"' "$PLANNING_DIR/config.json" > "$external_config"
  external_sha=$(file_sha_of "$external_config")
  install_shim "$TEST_ROOT/journal-after-swap-bin" cp <<'SHIM'
source_path=${1:-}
if [ "$source_path" = "$MODEL_SWAP_AFTER" ] && [ ! -e "$MODEL_SWAP_MARKER" ]; then
  "$REAL_MV" "$source_path" "$source_path.original"
  "$REAL_CP" "$MODEL_SWAP_EXTERNAL" "$source_path"
  : > "$MODEL_SWAP_MARKER"
fi
exec "$REAL_CP" "$@"
SHIM
  catalog_before=$(catalog_sha)
  config_before=$(config_sha)

  run env \
    PATH="$TEST_ROOT/journal-after-swap-bin:$PATH" \
    REAL_CP="$REAL_CP" \
    REAL_MV="$REAL_MV" \
    MODEL_SWAP_AFTER="$pending/config.after" \
    MODEL_SWAP_EXTERNAL="$external_config" \
    MODEL_SWAP_MARKER="$marker" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -ne 0 ]
  [ -e "$marker" ]
  assert_state_unchanged "$config_before" "$catalog_before"
  [ "$external_sha" = "$(file_sha_of "$external_config")" ]
  [ -e "$PLANNING_DIR/.lbwc-model-refresh.pending" ]
}

@test "refresh rejects a swapped before image during rollback without changing either state file" {
  local config_before catalog_before external_sha marker="$TEST_ROOT/journal-before-swapped"
  local external_config="$TEST_ROOT/external-config-before" pending
  pending="$(physical_planning_dir)/.lbwc-model-refresh.pending"
  jq '.effort = "turbo"' "$PLANNING_DIR/config.json" > "$external_config"
  external_sha=$(file_sha_of "$external_config")
  install_shim "$TEST_ROOT/journal-before-swap-bin" mv <<'SHIM'
destination=${!#}
if [ "$destination" = "$MODEL_SWAP_CATALOG" ] &&
  [ ! -e "$MODEL_SWAP_MARKER" ]; then
  "$REAL_MV" "$MODEL_SWAP_BEFORE" "$MODEL_SWAP_BEFORE.original"
  "$REAL_CP" "$MODEL_SWAP_EXTERNAL" "$MODEL_SWAP_BEFORE"
  : > "$MODEL_SWAP_MARKER"
  exit 73
fi
exec "$REAL_MV" "$@"
SHIM
  catalog_before=$(catalog_sha)
  config_before=$(config_sha)

  run env \
    PATH="$TEST_ROOT/journal-before-swap-bin:$PATH" \
    REAL_CP="$REAL_CP" \
    REAL_MV="$REAL_MV" \
    MODEL_SWAP_BEFORE="$pending/config.before" \
    MODEL_SWAP_EXTERNAL="$external_config" \
    MODEL_SWAP_CATALOG="$(physical_planning_dir)/claude-capabilities.json" \
    MODEL_SWAP_MARKER="$marker" \
    CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" \
    bash "$SCRIPT" refresh "$PLANNING_DIR"

  [ "$status" -ne 0 ]
  [ -e "$marker" ]
  assert_state_unchanged "$config_before" "$catalog_before"
  [ "$external_sha" = "$(file_sha_of "$external_config")" ]
  [ -e "$PLANNING_DIR/.lbwc-model-refresh.pending" ]
}

@test "a surviving refresh marker blocks every model writer and trusted state entry point" {
  local config_before catalog_before
  mkdir "$PLANNING_DIR/.lbwc-model-refresh.pending"
  catalog_before=$(catalog_sha)
  config_before=$(config_sha)

  while IFS='|' read -r label tool arguments; do
    [ -n "$label" ] || continue

    run env CLAUDE_CODE_EXECPATH="$CLAUDE_FIXTURE" bash "$(tool_path "$tool")" ${arguments//@PLANNING@/$PLANNING_DIR} </dev/null

    [ "$status" -ne 0 ] || { case_fail "$label" "entry point succeeded"; return 1; }
    [[ "$output" == *'pending model refresh requires recovery'* ]] \
      || { case_fail "$label" "missing recovery message"; return 1; }
    assert_state_unchanged "$config_before" "$catalog_before" || { case_fail "$label" "state changed"; return 1; }
  done <<'CASES'
model-set|model|set @PLANNING@ quality docs ember-path null
model-activate|model|activate @PLANNING@ turbo
model-copy|model|copy @PLANNING@ quality turbo
model-refresh|model|refresh @PLANNING@
model-show|model|show @PLANNING@
config-set|config|set @PLANNING@ effort "turbo"
routing-validate|routing|validate @PLANNING@
capabilities-refresh|capabilities|refresh @PLANNING@
capabilities-validate|capabilities|validate @PLANNING@/claude-capabilities.json
CASES
}
