#!/usr/bin/env bats

load gate_case_helper
load rejection_case_helper
load lbwc_config_helper

setup() {
  config_fixture_setup
}

teardown() {
  config_fixture_teardown
}

make_planning_swap_mv() {
  local shim_dir="$TEST_ROOT/shim"
  mkdir -p "$shim_dir"
  cat > "$shim_dir/mv" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 3 ] && [ "$1" = "-f" ] || exit 64
source_path="$2"
destination_path="$3"
/bin/mv "$SWAP_PLANNING_DIR" "$SWAP_OPENED_DIR"
ln -s "$SWAP_EXTERNAL_DIR" "$SWAP_PLANNING_DIR"
if [[ "$source_path" = "/"* ]]; then
  source_path="$SWAP_OPENED_DIR/${source_path##*/}"
fi
exec /bin/mv -f "$source_path" "$destination_path"
SHIM
  chmod +x "$shim_dir/mv"
  printf '%s\n' "$shim_dir"
}

@test "init creates a versioned configuration with routing, preference defaults and legacy migration" {
  local legacy_dir="$TEST_ROOT/legacy/.lbwc-planning"

  init_config "$PLANNING_DIR"
  expect_config_jq fresh-routing-defaults "$PLANNING_DIR" '
    .schema_version == 1
    and .effort == "balanced"
    and .routing.active_profile == "balanced"
    and .routing.profiles.quality.roles == {}
    and .routing.profiles.balanced.roles == {}
    and .routing.profiles.turbo.roles == {}
  '
  expect_config_jq fresh-preference-defaults "$PLANNING_DIR" '
    .skill_suggestions == true
    and .auto_install_skills == false
    and .discovery_questions == true
    and .discussion_mode == "questions"
    and .visual_format == "unicode"
    and .pipeline_research == false
    and .branch_per_milestone == false
    and .plain_summary == true
    and .active_profile == "default"
    and .custom_profiles == {}
    and .agent_max_turns == {}
    and .qa_skip_agents == []
    and .token_budgets == true
    and .two_phase_completion == true
    and .smart_routing == true
    and .validation_gates == true
    and .snapshot_resume == true
    and .lease_locks == true
    and .event_recovery == true
    and .worktree_isolation == "off"
    and .monorepo_routing == true
    and .debug_logging == false
    and .statusline_hide_limits == false
    and .statusline_hide_limits_for_api_key == false
    and .statusline_hide_agent_in_tmux == false
    and .statusline_collapse_agent_in_tmux == false
    and (has("model_profile") | not)
    and (has("model_overrides") | not)
    and (has("model_matrix") | not)
    and (has("model_catalog") | not)
    and (has("reasoning_matrix") | not)
  '

  mkdir -p "$legacy_dir"
  printf '%s\n' '{"model_profile":"budget","roles":{"lead":{"model":"legacy-selector"}},"metrics":true,"skill_suggestions":false,"custom_profiles":{"release":{"effort":"thorough","autonomy":"cautious","verification_tier":"deep"}},"active_profile":"release"}' \
    > "$legacy_dir/config.json"
  init_config "$legacy_dir"
  expect_config_jq legacy-settings-preserved "$legacy_dir" '
    .model_profile == "budget"
    and .roles.lead.model == "legacy-selector"
    and .metrics == true
    and .skill_suggestions == false
    and .active_profile == "release"
    and .custom_profiles.release.verification_tier == "deep"
    and .token_budgets == true
    and .statusline_hide_limits == false
    and .routing.active_profile == "turbo"
    and .routing.profiles.quality.roles == {}
  '

  assert_no_case_failures
}

@test "the platform bash executes the shared configuration transaction" {
  [ -x /bin/bash ] || skip '/bin/bash is unavailable'

  run /bin/bash "$SCRIPT" init "$PLANNING_DIR"

  [ "$status" -eq 0 ]
  [ -f "$PLANNING_DIR/config.json" ]
  [ ! -e "$PLANNING_DIR/.routing.lock" ]
}

@test "init accepts the macOS var temporary directory alias" {
  local logical_planning
  [[ "$TEST_ROOT" == "/private/var/"* ]] || skip 'temporary directory is not under /private/var'
  logical_planning="/var/${TEST_ROOT#/private/var/}/.lbwc-planning"

  run_config init "$logical_planning"

  [ "$status" -eq 0 ]
  [ -f "$PLANNING_DIR/config.json" ]
}

accepted_value_row() {
  run_config set "$PLANNING_DIR" "$1" "$2"
  expect_case "$1=$2" 0
}

get_value_row() {
  local label="$1" setting="$2" literal="$3" want="$4"
  run_config set "$PLANNING_DIR" "$setting" "$literal"
  expect_case "$label-set" 0
  run_config get "$PLANNING_DIR" "$setting"
  expect_case "$label-get" 0
  [ "$output" = "$want" ] || record_case_failure "$label-get" "expected=[$want] got=[$output]"
}

@test "set persists every accepted setting domain and get returns the stored JSON value" {
  init_config "$PLANNING_DIR"

  while IFS='|' read -r setting literal; do
    [ -n "$setting" ] || continue
    accepted_value_row "$setting" "$literal"
  done <<'VALUES'
skill_suggestions|false
auto_install_skills|true
discovery_questions|false
discussion_mode|"assumptions"
visual_format|"ascii"
pipeline_research|true
branch_per_milestone|true
plain_summary|false
custom_profiles|{"release":{"effort":"thorough","autonomy":"cautious","verification_tier":"deep"}}
active_profile|"release"
agent_max_turns|{"lead":{"thorough":120,"turbo":false},"qa":0}
agent_max_turns|{"dev":50}
qa_skip_agents|["docs","qa-author"]
token_budgets|false
two_phase_completion|false
smart_routing|false
validation_gates|false
snapshot_resume|false
lease_locks|false
event_recovery|false
worktree_isolation|"on"
monorepo_routing|false
debug_logging|true
statusline_hide_limits|true
statusline_hide_limits_for_api_key|true
statusline_hide_agent_in_tmux|true
statusline_collapse_agent_in_tmux|true
effort|"thorough"
effort|"balanced"
effort|"fast"
effort|"turbo"
autonomy|"cautious"
autonomy|"standard"
autonomy|"confident"
autonomy|"pure-vibe"
auto_commit|false
auto_commit|true
planning_tracking|"manual"
planning_tracking|"ignore"
planning_tracking|"commit"
auto_push|"never"
auto_push|"after_phase"
auto_push|"always"
verification_tier|"quick"
verification_tier|"standard"
verification_tier|"deep"
context_compiler|false
context_compiler|true
max_tasks_per_plan|1
prefer_teams|"always"
prefer_teams|"auto"
prefer_teams|"never"
auto_uat|true
auto_uat|false
require_phase_discussion|true
require_phase_discussion|false
rolling_summary|true
rolling_summary|false
metrics|true
metrics|false
caveman_style|"none"
caveman_style|"lite"
caveman_style|"full"
caveman_style|"ultra"
caveman_style|"auto"
caveman_commit|true
caveman_commit|false
caveman_review|true
caveman_review|false
max_uat_remediation_rounds|1
max_uat_remediation_rounds|false
routing.active_profile|"quality"
routing.active_profile|"balanced"
routing.active_profile|"turbo"
VALUES

  get_value_row get-string effort '"turbo"' '"turbo"'
  get_value_row get-stored-false auto_commit false false

  assert_no_case_failures
}

config_row_dir() {
  printf '%s\n' "$TEST_ROOT/$1/.lbwc-planning"
}

@test "set, init and validate reject invalid values, invalid existing configurations and symbolic links without changing the saved configuration" {
  local external="$TEST_ROOT/external" dir

  init_config "$PLANNING_DIR"

  while IFS='|' read -r setting literal; do
    [ -n "$setting" ] || continue
    reject_unchanged_row "$setting=$literal" "$PLANNING_DIR" "invalid configuration" \
      set "$PLANNING_DIR" "$setting" "$literal"
  done <<'VALUES'
discussion_mode|"freeform"
visual_format|"ansi"
active_profile|"release profile"
active_profile|"unknown"
custom_profiles|{"default":{"effort":"balanced","autonomy":"standard","verification_tier":"standard"}}
agent_max_turns|{"unknown":1}
qa_skip_agents|["docs","docs"]
worktree_isolation|"maybe"
effort|"invalid"
effort|"slow"
autonomy|"unbounded"
auto_commit|"true"
planning_tracking|"automatic"
auto_push|"sometimes"
verification_tier|"none"
context_compiler|"true"
max_tasks_per_plan|0
prefer_teams|"sometimes"
auto_uat|"false"
require_phase_discussion|"false"
rolling_summary|"false"
metrics|"false"
caveman_style|"extreme"
caveman_commit|"false"
caveman_review|"false"
max_uat_remediation_rounds|"many"
routing.active_profile|"budget"
VALUES

  dir=$(config_row_dir unknown-root-key)
  mkdir -p "$dir"
  printf '%s\n' '{"unknown_setting":true}' > "$dir/config.json"
  reject_unchanged_row unknown-root-key "$dir" "invalid configuration" init "$dir"

  dir=$(config_row_dir unsupported-version)
  mkdir -p "$dir"
  printf '%s\n' '{"schema_version":99,"effort":"balanced"}' > "$dir/config.json"
  reject_unchanged_row unsupported-version "$dir" "unsupported configuration version" init "$dir"

  dir=$(config_row_dir missing-routing-profile)
  mkdir -p "$dir"
  printf '%s\n' '{"schema_version":1,"effort":"balanced","routing":{"active_profile":"balanced","profiles":{"quality":{"roles":{}},"balanced":{"roles":{}}}}}' \
    > "$dir/config.json"
  reject_unchanged_row missing-routing-profile "$dir" "invalid configuration" validate "$dir"

  dir=$(config_row_dir unexpected-routing-profile)
  init_config "$dir"
  jq '.routing.profiles.shadow = {roles:{}}' "$dir/config.json" > "$dir/config.json.tmp"
  mv "$dir/config.json.tmp" "$dir/config.json"
  reject_unchanged_row unexpected-routing-profile "$dir" "invalid configuration" validate "$dir"

  mkdir -p "$external"
  dir="$TEST_ROOT/linked-planning/.lbwc-planning"
  mkdir -p "$(dirname "$dir")"
  ln -s "$external" "$dir"
  run_config init "$dir"
  expect_rejected symlinked-planning-directory "symbolic link"
  [ ! -e "$external/config.json" ] || record_case_failure symlinked-planning-directory "target was written"

  ln -s "$external" "$TEST_ROOT/linked-parent"
  run_config init "$TEST_ROOT/linked-parent/project/.lbwc-planning"
  expect_rejected symlinked-intermediate-directory "symbolic link"
  [ ! -e "$external/project" ] || record_case_failure symlinked-intermediate-directory "target was created"

  dir=$(config_row_dir symlinked-config)
  mkdir -p "$dir"
  ln -s "$external/config.json" "$dir/config.json"
  run_config init "$dir"
  expect_rejected symlinked-config-path "symbolic link"
  [ ! -e "$external/config.json" ] || record_case_failure symlinked-config-path "target was created"

  dir=$(config_row_dir symlinked-lock)
  mkdir -p "$dir"
  ln -s "$external" "$dir/.config.lock"
  run_config init "$dir"
  expect_rejected symlinked-lock-path "symbolic link"
  [ ! -e "$dir/config.json" ] || record_case_failure symlinked-lock-path "configuration was written"

  assert_no_case_failures
}

expected_effort_for_status() {
  case "$1" in
    0) printf '%s\n' turbo ;;
    *) printf '%s\n' balanced ;;
  esac
}

@test "set keeps the verified planning directory identity during final rename" {
  local external_dir="$TEST_ROOT/external" opened_dir="$TEST_ROOT/opened-planning"
  local external_before shim_dir command_status
  init_config "$PLANNING_DIR"
  mkdir -p "$external_dir"
  printf '%s\n' 'external sentinel' > "$external_dir/config.json"
  external_before=$(shasum -a 256 "$external_dir/config.json" | awk '{print $1}')
  shim_dir=$(make_planning_swap_mv)

  run env \
    PATH="$shim_dir:$PATH" \
    SWAP_PLANNING_DIR="$PLANNING_DIR" \
    SWAP_OPENED_DIR="$opened_dir" \
    SWAP_EXTERNAL_DIR="$external_dir" \
    bash "$SCRIPT" set "$PLANNING_DIR" effort '"turbo"'
  command_status="$status"

  [ "$external_before" = "$(shasum -a 256 "$external_dir/config.json" | awk '{print $1}')" ]
  [ -L "$PLANNING_DIR" ]
  [ -f "$opened_dir/config.json" ]
  [ "$(jq -r '.effort' "$opened_dir/config.json")" = "$(expected_effort_for_status "$command_status")" ]
}

doc_default_turns() {
  awk -F'|' '$2 ~ /^ agent_max_turns $/ { print $5 }' "$BATS_TEST_DIRNAME/../commands/config.md" \
    | tr ',' '\n' | sed -n "s/^ *$1=\([0-9][0-9]*\) *$/\1/p"
}

expect_doc_turns_match() {
  local label=$1 doc_role=$2 role_name=$3 documented shipped
  documented=$(doc_default_turns "$doc_role")
  shipped=$(jq -r --arg role "$role_name" '.[$role].maxTurns' "$BATS_TEST_DIRNAME/../templates/agent-roles/defaults.json")
  [ -n "$documented" ] && [ "$documented" = "$shipped" ] \
    || record_case_failure "$label" "documented=[$documented] shipped=[$shipped]"
}

@test "agent_max_turns docs: the defaults row matches the shipped role maxTurns" {
  reset_case_failures

  expect_doc_turns_match scout scout scout
  expect_doc_turns_match qa qa qa
  expect_doc_turns_match architect architect architect
  expect_doc_turns_match debugger debugger debugger
  expect_doc_turns_match lead lead lead
  expect_doc_turns_match engineers-dijkstra engineers coding-dijkstra
  expect_doc_turns_match engineers-python engineers python-engineer
  expect_doc_turns_match engineers-web engineers web-engineer
  expect_doc_turns_match test-dev test-dev test-dev

  assert_no_case_failures
}
