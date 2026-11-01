#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  CLAUDE_HOME="$TEST_TEMP_DIR/claude-config"
  PLUGIN_CACHE="$CLAUDE_HOME/plugins/cache/lbwc-marketplace/lbwc"
  TMP_ROOT="$TEST_TEMP_DIR/tmp-root"
  OWN_UID=$(id -u)
  OTHER_UID=$((OWN_UID + 1))
  cd "$TEST_TEMP_DIR"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

reset_caches() {
  rm -rf "$CLAUDE_HOME" "$TMP_ROOT"
  mkdir -p "$TMP_ROOT"
  local version
  for version in "$@"; do
    mkdir -p "$PLUGIN_CACHE/$version/scripts"
  done
}

plant_temp_caches() {
  : > "$TMP_ROOT/lbwc-phase-$OWN_UID-abc"
  : > "$TMP_ROOT/lbwc-map-$OWN_UID"
  : > "$TMP_ROOT/lbwc-update-check-$OWN_UID"
  : > "$TMP_ROOT/lbwc-phase-$OTHER_UID-abc"
}

nuke_and_list() {
  env HOME="$TEST_TEMP_DIR" CLAUDE_CONFIG_DIR="$CLAUDE_HOME" LBWC_TMP_CACHE_ROOT="$TMP_ROOT" \
    bash "$SCRIPTS_DIR/cache-nuke.sh" "$@" || return
  printf 'versions-left=%s;\n' "$(ls "$PLUGIN_CACHE" 2>/dev/null | tr '\n' ',')"
  printf 'temp-left=%s;\n' "$(ls -A "$TMP_ROOT" | tr '\n' ',')"
}

@test "cache nuke wipes the plugin cache and this user's temp caches or keeps the latest version" {
  reset_caches
  run nuke_and_list
  expect_case nothing-cached 0 '{"wiped":{"plugin_cache":false,"temp_caches":false,"versions_removed":0}}'

  reset_caches 1.0.1 1.0.2
  plant_temp_caches
  run nuke_and_list
  expect_case full-wipe 0 '{"wiped":{"plugin_cache":true,"temp_caches":true,"versions_removed":2}}'
  expect_case full-wipe 0 "versions-left=;"
  expect_case full-wipe 0 "temp-left=lbwc-phase-$OTHER_UID-abc,;"

  reset_caches 1.0.9 1.0.10 1.0.2
  run nuke_and_list --keep-latest
  expect_case keep-latest 0 '{"wiped":{"plugin_cache":true,"temp_caches":false,"versions_removed":2}}'
  expect_case keep-latest 0 "versions-left=1.0.10,;"

  reset_caches 1.0.4
  run nuke_and_list --keep-latest
  expect_case keep-latest-single 0 '{"wiped":{"plugin_cache":false,"temp_caches":false,"versions_removed":0}}'
  expect_case keep-latest-single 0 "versions-left=1.0.4,;"

  assert_no_case_failures
}
