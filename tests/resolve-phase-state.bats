#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  bats_require_minimum_version 1.5.0
  setup_temp_dir
  SID_PREFIX="covw2-rps-$$-$BATS_TEST_NUMBER"
  mkdir -p "$TEST_TEMP_DIR/project/.meridian"
  git -C "$TEST_TEMP_DIR/project" init -q
  cd "$TEST_TEMP_DIR/project"
  : > "$TEST_TEMP_DIR/fallback-links"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  rm -rf /tmp/.meridian-plugin-root-link-"$SID_PREFIX"-* /tmp/.meridian-phase-detect-"$SID_PREFIX"-* /tmp/.meridian-phase-detect-live-"$SID_PREFIX"-*
  local link key
  while IFS= read -r link; do
    key=${link##*/.meridian-plugin-root-link-}
    rm -rf "$link" "/tmp/.meridian-phase-detect-$key.txt" "/tmp/.meridian-phase-detect-live-$key.lock"
  done < "$TEST_TEMP_DIR/fallback-links"
  teardown_temp_dir
}

fake_plugin() {
  local root="$TEST_TEMP_DIR/plugin-$1"
  mkdir -p "$root/scripts"
  cp "$SCRIPTS_DIR/ensure-plugin-root-link.sh" "$root/scripts/"
  printf '%s\n' '#!/usr/bin/env bash' "$2" > "$root/scripts/phase-detect.sh"
  printf '%s\n' "$root"
}

resolve_state() {
  local sid="$SID_PREFIX-$1" root="$2"
  CLAUDE_SESSION_ID="$sid" CLAUDE_PLUGIN_ROOT="$root" bash "$SCRIPTS_DIR/resolve-phase-state.sh"
}

lock_dir() {
  printf '/tmp/.meridian-phase-detect-live-%s-%s.lock\n' "$SID_PREFIX" "$1"
}

fallback_state_row() {
  local label="$1" project="$2" plugin="$3" previous_link="$4" previous_root="$5" link key previous_key
  cd "$project"
  run env -u CLAUDE_SESSION_ID CLAUDE_PLUGIN_ROOT="$plugin" bash "$SCRIPTS_DIR/resolve-phase-state.sh"
  expect_case "$label" 0 "phase_detect_complete=true"
  link=${output%%$'\n'*}
  printf '%s\n' "$link" >> "$TEST_TEMP_DIR/fallback-links"
  [ "$link" != "$previous_link" ] || record_case_failure "$label" "fallback link reused across roots"
  [ "$(readlink "$previous_link")" = "$previous_root" ] \
    || record_case_failure "$label" "previous plugin link changed"
  [ "$(readlink "$link")" = "$plugin" ] || record_case_failure "$label" "new link resolves to another plugin"
  key=${link##*/.meridian-plugin-root-link-}
  previous_key=${previous_link##*/.meridian-plugin-root-link-}
  cmp -s "/tmp/.meridian-phase-detect-$previous_key.txt" "$TEST_TEMP_DIR/first-phase-state" \
    || record_case_failure "$label" "previous phase state changed"
  [ -s "/tmp/.meridian-phase-detect-$key.txt" ] || record_case_failure "$label" "isolated phase state missing"
}

fallback_roots_keep_independent_state() {
  local plugin="$TEST_TEMP_DIR/real-plugin" other_plugin="$TEST_TEMP_DIR/other-plugin" first_link first_key
  mkdir -p "$plugin" "$other_plugin" "$TEST_TEMP_DIR/other-project"
  cp -R "$SCRIPTS_DIR" "$plugin/scripts"
  cp -R "$SCRIPTS_DIR" "$other_plugin/scripts"
  git -C "$TEST_TEMP_DIR/other-project" init -q
  plugin=$(cd "$plugin" && pwd -P)
  other_plugin=$(cd "$other_plugin" && pwd -P)
  cd "$TEST_TEMP_DIR/project"
  run env -u CLAUDE_SESSION_ID CLAUDE_PLUGIN_ROOT="$plugin" bash "$SCRIPTS_DIR/resolve-phase-state.sh"
  expect_case fallback-baseline 0 "phase_detect_complete=true"
  first_link=${output%%$'\n'*}
  printf '%s\n' "$first_link" >> "$TEST_TEMP_DIR/fallback-links"
  first_key=${first_link##*/.meridian-plugin-root-link-}
  cp "/tmp/.meridian-phase-detect-$first_key.txt" "$TEST_TEMP_DIR/first-phase-state"
  fallback_state_row different-project "$TEST_TEMP_DIR/other-project" "$plugin" "$first_link" "$plugin"
  fallback_state_row different-plugin "$TEST_TEMP_DIR/project" "$other_plugin" "$first_link" "$plugin"
  cd "$TEST_TEMP_DIR/project"
}

empty_digest_stops_phase_resolution() {
  mkdir -p "$TEST_TEMP_DIR/bin"
  printf '#!/bin/sh\ncat >/dev/null\n' > "$TEST_TEMP_DIR/bin/shasum"
  chmod +x "$TEST_TEMP_DIR/bin/shasum"
  run --separate-stderr env -u CLAUDE_SESSION_ID PATH="$TEST_TEMP_DIR/bin:$PATH" CLAUDE_PLUGIN_ROOT="$PROJECT_ROOT" bash "$SCRIPTS_DIR/resolve-phase-state.sh"
  expect_case_silent empty-digest 1
}

@test "phase state resolution prints the session link and fresh detector output or an error marker" {
  local healthy failing flaky lock finished_pid
  healthy=$(fake_plugin healthy 'printf "next_phase_state=needs_plan\nphase_detect_complete=true\n"')
  failing=$(fake_plugin failing 'exit 1')
  flaky=$(fake_plugin flaky 'n=$(cat "$(dirname "$0")/calls" 2>/dev/null || echo 0); echo $((n + 1)) > "$(dirname "$0")/calls"; [ "$n" -ge 1 ] || exit 1; echo "next_phase_state=needs_execute"')

  run resolve_state healthy "$healthy"
  expect_case healthy 0 "/tmp/.meridian-plugin-root-link-$SID_PREFIX-healthy"$'\n'"next_phase_state=needs_plan"

  run resolve_state failing "$failing"
  expect_case failing-detector 0 "phase_detect_error=true"

  run resolve_state flaky "$flaky"
  expect_case detector-recovers-on-retry 0 "next_phase_state=needs_execute"
  expect_case_absent detector-recovers-on-retry "phase_detect_error"

  run resolve_state no-root "$TEST_TEMP_DIR/absent-plugin"
  expect_case no-plugin-root 0 "/tmp/.meridian-plugin-root-link-$SID_PREFIX-no-root"$'\n'"phase_detect_error=true"

  lock=$(lock_dir dead-owner)
  mkdir -p "$lock"
  sleep 0 &
  finished_pid=$!
  wait "$finished_pid"
  printf '%s\n' "$finished_pid" > "$lock/pid"
  run resolve_state dead-owner "$healthy"
  expect_case dead-lock-owner 0 "next_phase_state=needs_plan"

  lock=$(lock_dir live-owner)
  mkdir -p "$lock"
  sleep 1 >/dev/null 2>&1 3>&- &
  printf '%s\n' "$!" > "$lock/pid"
  run resolve_state live-owner "$healthy"
  expect_case lock-released-by-exiting-owner 0 "next_phase_state=needs_plan"

  lock=$(lock_dir old-lock)
  mkdir -p "$lock"
  touch -t 200001010000 "$lock"
  run resolve_state old-lock "$healthy"
  expect_case old-ownerless-lock 0 "next_phase_state=needs_plan"

  fallback_roots_keep_independent_state
  empty_digest_stops_phase_resolution

  assert_no_case_failures
}
