#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper
load rejection_case_helper
load routing_fixture

ROUTING="${LBWC_ROUTING_UNDER_TEST:-${SCRIPTS_DIR}/lbwc-routing.sh}"

setup() {
  routing_fixture_setup
}

teardown() {
  routing_fixture_teardown
}

set_accepted_row() {
  local label="$1" profile="$2" role="$3" model="$4" reasoning="$5" expected="$6"
  restore_planning
  run bash "$ROUTING" set "$PLANNING" "$profile" "$role" "$model" "$reasoning"
  expect_case "$label" 0
  expect_jq "$label" "$PLANNING/config.json" ".routing.profiles.$profile.roles.$role == $expected"
}

check_set_rejected() {
  local label="$1" fragment="$2" before
  shift 2
  before=$(config_digest)
  run bash "$ROUTING" set "$PLANNING" "$@"
  expect_rejected "$label" "$fragment"
  expect_digest "$label" "$before" "$(config_digest)"
}

store_catalog_routes_and_reject_invalid_requests() {
  local external external_before
  snapshot_planning

  while IFS='|' read -r label profile role model reasoning expected; do
    [ -n "$label" ] || continue
    set_accepted_row "$label" "$profile" "$role" "$model" "$reasoning" "$expected"
  done <<'CASES'
exact-route|quality|architect|nova-route|"deliberate"|{model: "nova-route", reasoning: "deliberate", status: "resolved"}
structural-null|balanced|docs|ember-path|null|{model: "ember-path", reasoning: null, status: "resolved"}
global-reasoning-ignores-associations|quality|architect|nova-route|"swift"|{model: "nova-route", reasoning: "swift", status: "resolved"}
CASES
  restore_planning

  check_set_rejected missing-selector "not present in the saved capability catalog" \
    quality architect missing-route '"deliberate"'

  check_set_rejected unknown-role "unknown routing role" quality unknown-role ember-path '"swift"'

  edit_json "$PLANNING/config.json" '.routing.profiles.experimental = {roles: {}}'
  check_set_rejected malformed-profile-table "exactly quality, balanced, and turbo" \
    quality docs ember-path '"swift"'
  restore_planning

  external="$TEST_TEMP_DIR/external-config.json"
  printf '%s\n' '{"sentinel":true}' > "$external"
  external_before=$(shasum -a 256 "$external" | awk '{print $1}')
  rm "$PLANNING/config.json"
  ln -s "$external" "$PLANNING/config.json"
  run bash "$ROUTING" set "$PLANNING" quality docs ember-path '"swift"'
  expect_rejected symlinked-config "symbolic link"
  [ "$external_before" = "$(shasum -a 256 "$external" | awk '{print $1}')" ] \
    || record_case_failure symlinked-config "symlink target changed"
  [ -L "$PLANNING/config.json" ] || record_case_failure symlinked-config "symlink was replaced"
  restore_planning

  printf '%s\n' 'changed' >> "$ROUTE_BINARY"
  check_set_rejected catalog-binary-changed "fingerprint differs" turbo docs ember-path null

  assert_no_case_failures
}

check_host_enum_case() {
  local label="$1" enum_state="$2" selector="$3" expected_status="$4" expected_text="$5"
  local catalog="$PLANNING/claude-capabilities.json"
  [ -f "$catalog.base" ] || cp "$catalog" "$catalog.base"
  if [ "$enum_state" = "enum" ]; then
    jq '. + {host_agent_enum: ["sonnet"], agent_model_ids: {sonnet: "sonnet"}}
      | .models += [{selector: "sonnet", label: "Sonnet", description: "Host fixture"}]' \
      "$catalog.base" > "$catalog"
  else
    cp "$catalog.base" "$catalog"
  fi

  run bash "$ROUTING" check "$PLANNING" "$selector" '"deliberate"'

  expect_case "$label" "$expected_status" "$expected_text"
}

check_host_agent_enum_when_present() {
  while IFS='|' read -r label enum_state selector expected_status expected_text; do
    [ -n "$label" ] || continue
    check_host_enum_case "$label" "$enum_state" "$selector" "$expected_status" "$expected_text"
  done <<'CASES'
selector-without-host-id|enum|nova-route|1|not present in the live host Agent enum
selector-with-host-id|enum|sonnet|0|
catalog-without-host-enum|none|nova-route|0|
CASES

  assert_no_case_failures
}

check_migrate_unchanged_rejection() {
  local label="$1" fragment="$2" before
  before=$(config_digest)
  run bash "$ROUTING" migrate "$PLANNING"
  expect_rejected "$label" "$fragment"
  expect_digest "$label" "$before" "$(config_digest)"
}

manage_resolved_routes_without_mutating_invalid_state() {
  local before
  snapshot_planning

  bash "$ROUTING" set "$PLANNING" quality architect nova-route '"deliberate"' >/dev/null
  run bash "$ROUTING" copy "$PLANNING" quality turbo
  expect_case copy-profile 0
  run bash "$ROUTING" activate "$PLANNING" turbo
  expect_case activate-profile 0
  expect_jq three-profiles-persisted "$PLANNING/config.json" '
    .routing.active_profile == "turbo"
    and .routing.profiles.turbo.roles == .routing.profiles.quality.roles
    and (.routing.profiles | keys | sort) == ["balanced", "quality", "turbo"]
  '
  restore_planning

  bash "$ROUTING" set "$PLANNING" balanced docs ember-path null >/dev/null
  bash "$ROUTING" set "$PLANNING" quality docs ember-path '"swift"' >/dev/null

  run bash "$ROUTING" resolve "$PLANNING" docs
  expect_case active-profile-route 0
  [ "$output" = '{"model":"ember-path","profile":"balanced","reasoning":null,"role":"docs"}' ] \
    || record_case_failure active-profile-route "unexpected output=$output"

  run bash "$ROUTING" resolve "$PLANNING" docs quality
  expect_case explicit-profile-route 0
  [ "$output" = '{"model":"ember-path","profile":"quality","reasoning":"swift","role":"docs"}' ] \
    || record_case_failure explicit-profile-route "unexpected output=$output"

  run bash "$ROUTING" validate "$PLANNING"
  expect_case validate-resolved-table 0
  restore_planning

  printf '%s\n' '{"status":"executing"}' > "$PLANNING/.execution-state.json"
  before=$(config_digest)
  run bash "$ROUTING" activate "$PLANNING" turbo
  expect_rejected activate-while-executing frozen
  expect_digest activate-while-executing "$before" "$(config_digest)"
  restore_planning

  edit_json "$PLANNING/config.json" '.routing.active_profile = "budget"'
  printf '%s\n' '{"status":"executing"}' > "$PLANNING/.execution-state.json"
  check_migrate_unchanged_rejection migrate-while-executing frozen
  restore_planning

  edit_json "$PLANNING/config.json" '.roles.intruder = {model: "ember-path", effort: "swift"}'
  check_migrate_unchanged_rejection migrate-unknown-legacy-role "unknown routing role"
  restore_planning

  edit_json "$PLANNING/config.json" \
    '.routing.profiles.quality.roles.docs = {model: "removed-route", reasoning: null, status: "resolved"}'
  before=$(config_digest)
  run bash "$ROUTING" copy "$PLANNING" quality turbo
  expect_rejected copy-invalid-source-route ""
  expect_digest copy-invalid-source-route "$before" "$(config_digest)"
  restore_planning

  run bash "$ROUTING" resolve "$PLANNING" docs
  expect_rejected resolve-absent-route "route is unresolved or absent"

  edit_json "$PLANNING/config.json" '.routing.profiles.experimental = {roles: {}}'
  run bash "$ROUTING" validate "$PLANNING"
  expect_rejected validate-extra-profile "exactly quality, balanced, and turbo"
  restore_planning

  edit_json "$PLANNING/config.json" '.routing.profiles.quality.roles.docs = {model: "ember-path", reasoning: null, status: "unresolved"}'
  run bash "$ROUTING" validate "$PLANNING"
  expect_rejected validate-unresolved-route "unresolved routing cell"

  assert_no_case_failures
}

migrate_row() {
  local label="$1" expected="$2"
  run bash "$ROUTING" migrate "$PLANNING"
  expect_case "$label" 0
  expect_jq "$label" "$PLANNING/config.json" "$expected"
}

migrate_legacy_routes_and_reasoning() {
  local first second
  snapshot_planning

  edit_json "$PLANNING/config.json" '
    .model_profile = "budget"
    | .routing.active_profile = "budget"
    | .routing.profiles.budget = {
        roles: {
          docs: {model: "ember-path", reasoning: "swift"},
          architect: {model: "removed-route", reasoning: "deliberate"}
        }
      }
  '
  migrate_row budget-becomes-turbo '
    .routing.active_profile == "turbo"
    and (.routing.profiles | keys | sort) == ["balanced", "quality", "turbo"]
    and .routing.profiles.turbo.roles.docs
      == {model: "ember-path", reasoning: "swift", status: "resolved"}
    and .routing.profiles.turbo.roles.architect
      == {model: "removed-route", reasoning: "deliberate", status: "unresolved"}
  '
  restore_planning

  edit_json "$PLANNING/config.json" '
    .routing.active_profile = "quality"
    | .roles = {
        docs: {model: "ember-path", effort: "swift", max_turns: 33},
        architect: {model: "removed-route", effort: "deliberate"}
      }
  '
  migrate_row legacy-roles-preserved '
    .routing.profiles.quality.roles.docs
      == {model: "ember-path", reasoning: "swift", status: "resolved"}
    and .routing.profiles.quality.roles.architect
      == {model: "removed-route", reasoning: "deliberate", status: "unresolved"}
    and .roles.docs == {max_turns: 33}
    and .roles.architect == {}
  '
  first=$(config_digest)
  run bash "$ROUTING" migrate "$PLANNING"
  expect_case legacy-roles-idempotent 0
  second=$(config_digest)
  expect_digest legacy-roles-idempotent "$first" "$second"
  restore_planning

  edit_json "$PLANNING/claude-capabilities.json" '
    .models += [{selector: "quartz-freeform", label: "Quartz Freeform", description: "Global reasoning fixture"}]
    | .reasoning.accepted_values += ["depth-99"]
    | .reasoning.model_associations["quartz-freeform"] = ["default"]
  '
  edit_json "$PLANNING/config.json" '
    .routing.profiles.quality.roles.docs = {
      model: "quartz-freeform",
      reasoning: "depth-99",
      status: "resolved"
    }
  '
  migrate_row global-reasoning-needs-no-association \
    '.routing.profiles.quality.roles.docs.status == "resolved"'
  run bash "$ROUTING" resolve "$PLANNING" docs quality
  expect_case global-reasoning-resolves 0
  [ "$output" = '{"model":"quartz-freeform","profile":"quality","reasoning":"depth-99","role":"docs"}' ] \
    || record_case_failure global-reasoning-resolves "unexpected output=$output"
  restore_planning

  edit_json "$PLANNING/claude-capabilities.json" '.reasoning.scope = "model_associated"'
  edit_json "$PLANNING/config.json" '
    .routing.profiles.quality.roles.docs = {
      model: "nova-route",
      reasoning: "swift",
      status: "resolved"
    }
  '
  migrate_row model-associated-reasoning-enforced '
    .routing.profiles.quality.roles.docs
    == {model: "nova-route", reasoning: "swift", status: "unresolved"}
  '

  assert_no_case_failures
}

boundary_rejected_row() {
  local label="$1" fragment="$2"
  shift 2
  run bash "$ROUTING" "$@"
  expect_rejected "$label" "$fragment"
}

reject_paths_outside_planning_boundary() {
  local other="$TEST_TEMP_DIR/not-planning"
  local target="$TEST_TEMP_DIR/real/.lbwc-planning"
  local linked="$TEST_TEMP_DIR/linked/.lbwc-planning" before
  mkdir -p "$other" "$target" "$(dirname "$linked")"
  cp "$PLANNING/config.json" "$PLANNING/claude-capabilities.json" "$other/"
  cp "$PLANNING/config.json" "$PLANNING/claude-capabilities.json" "$target/"
  ln -s "$target" "$linked"
  before=$(config_digest "$target")

  boundary_rejected_row outside-set "must end with .lbwc-planning" set "$other" quality docs ember-path '"swift"'
  boundary_rejected_row outside-copy "must end with .lbwc-planning" copy "$other" quality turbo
  boundary_rejected_row outside-activate "must end with .lbwc-planning" activate "$other" turbo
  boundary_rejected_row outside-migrate "must end with .lbwc-planning" migrate "$other"
  boundary_rejected_row outside-resolve "must end with .lbwc-planning" resolve "$other" docs
  boundary_rejected_row outside-check "must end with .lbwc-planning" check "$other" ember-path '"swift"'
  boundary_rejected_row outside-validate "must end with .lbwc-planning" validate "$other"
  boundary_rejected_row traversal "traversal is not allowed" validate "$PLANNING/../.lbwc-planning"
  boundary_rejected_row symlinked-planning "must not be a symbolic link" \
    set "$linked" quality docs ember-path '"swift"'
  expect_digest symlinked-planning "$before" "$(config_digest "$target")"

  assert_no_case_failures
}

@test "planning boundary accepts the macOS var ancestor alias" {
  [ -L /var ] || skip "macOS /var alias is unavailable"
  VAR_TEST_DIR=$(mktemp -d /private/var/tmp/lbwc-routing-alias.XXXXXX)
  local aliased="/var/tmp/${VAR_TEST_DIR##*/}/.lbwc-planning"
  mkdir -p "$VAR_TEST_DIR/.lbwc-planning"
  cp "$PLANNING/config.json" "$VAR_TEST_DIR/.lbwc-planning/config.json"
  cp "$PLANNING/claude-capabilities.json" "$VAR_TEST_DIR/.lbwc-planning/claude-capabilities.json"

  run bash "$ROUTING" validate "$aliased"

  [ "$status" -eq 0 ]
}

@test "routing commands preserve validated profiles and enforce transaction boundaries" {
  run_scenario_cases store_catalog_routes_and_reject_invalid_requests \
    check_host_agent_enum_when_present manage_resolved_routes_without_mutating_invalid_state \
    migrate_legacy_routes_and_reasoning reject_paths_outside_planning_boundary \
    serialize_route_writers_and_reject_forged_transactions
}

serialize_route_writers_and_reject_forged_transactions() {
  local first_pid second_pid first_rc second_rc sleep_mark="$TEST_TEMP_DIR/second-writer-waiting"
  local before planning
  planning=$(cd -P "$PLANNING" && pwd -P)
  before=$(config_digest "$planning")

  run env \
    LBWC_CONFIG_TRANSACTION_ACTIVE=1 \
    LBWC_CONFIG_TRANSACTION_PLANNING_DIR="$planning" \
    LBWC_CONFIG_TRANSACTION_LOCK_DIR="$planning/.routing.lock" \
    LBWC_CONFIG_TRANSACTION_LOCK_IDENTITY='1:1' \
    LBWC_CONFIG_TRANSACTION_GUARD="$planning/.routing.lock.guard" \
    LBWC_CONFIG_TRANSACTION_FD=999 \
    LBWC_CONFIG_TRANSACTION_OWNER='forged' \
    bash "$ROUTING" set "$planning" balanced docs ember-path '"swift"'
  expect_rejected forged-inherited-transaction 'inherited configuration transaction descriptor is unavailable'
  expect_digest forged-inherited-transaction "$before" "$(config_digest "$planning")"

  run bash "$ROUTING" transaction "$planning" bash -c 'exit 47'
  expect_case failed-command-exit-status 47
  [ ! -e "$planning/.routing.lock" ] \
    || record_case_failure failed-command-releases-lock "lock directory remained"
  assert_no_case_failures

  install_blocking_jq

  start_blocked_writer
  first_pid=$!
  run_wrapped_routing ROUTING_SLEEP_MARK="$sleep_mark" \
    bash "$ROUTING" set "$PLANNING" balanced architect nova-route '"deliberate"' >/dev/null 2>&1 &
  second_pid=$!
  wait_for_file "$sleep_mark"
  : > "$TEST_TEMP_DIR/release-first-transform"
  wait "$first_pid"; first_rc=$?
  wait "$second_pid"; second_rc=$?

  [ "$first_rc" -eq 0 ]
  [ "$second_rc" -eq 0 ]
  jq -e '
    .routing.profiles.balanced.roles.docs
      == {model: "ember-path", reasoning: "swift", status: "resolved"}
    and .routing.profiles.balanced.roles.architect
      == {model: "nova-route", reasoning: "deliberate", status: "resolved"}
  ' "$PLANNING/config.json" >/dev/null
}
