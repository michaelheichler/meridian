#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper
load routing_fixture

ROUTING="${LBWC_ROUTING_UNDER_TEST:-${SCRIPTS_DIR}/lbwc-routing.sh}"

system_platform() {
  if [ -x /usr/bin/uname ]; then
    /usr/bin/uname -s
  else
    /bin/uname -s
  fi
}

rewrite_fixture_sources() {
  local fixture="$1" program="$2" lib_dir file
  shift 2
  lib_dir="$(dirname "$fixture")/lib"
  for file in "$fixture" "$lib_dir"/[a-z]*.sh; do
    [ -f "$file" ] || continue
    awk "$@" "$program" "$file" > "$file.rewritten"
    mv "$file.rewritten" "$file"
  done
}

create_routing_failure_fixture() {
  local mode="$1"
  local fixture_root="$TEST_TEMP_DIR/routing-$mode"
  local fixture="$fixture_root/scripts/lbwc-routing.sh"
  local denied="$fixture_root/unavailable"
  mkdir -p "$fixture_root/scripts" "$fixture_root/templates/agent-roles"
  copy_script_with_libs "$ROUTING" "$fixture"
  rewrite_fixture_sources "$fixture" '
    mode == "entropy" { gsub("/dev/urandom", denied) }
    mode == "unsupported" && /^  platform=\$\(system_name\)/ {
      print "  platform=UnsupportedFixture"
      next
    }
    mode == "missing" {
      gsub("/usr/bin/lockf", denied)
      gsub("/usr/bin/flock /bin/flock", denied " " denied)
    }
    { print }
  ' -v mode="$mode" -v denied="$denied"
  cp "$PROJECT_ROOT/templates/agent-roles/defaults.json" "$fixture_root/templates/agent-roles/defaults.json"
  chmod +x "$fixture"
  printf '%s\n' "$fixture"
}

write_od_stub() {
  local dir="$1" out="$2" err="$3" code="$4"
  mkdir -p "$dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    [ -z "$out" ] || printf 'printf "%%s\\n" %s\n' "$out"
    [ -z "$err" ] || printf 'printf "%%s\\n" %s >&2\n' "$err"
    printf 'exit %s\n' "$code"
  } > "$dir/od"
  chmod +x "$dir/od"
}

create_od_fixture() {
  local tag="$1"
  local stub_dir="$TEST_TEMP_DIR/$tag-bin"
  local fixture_root="$TEST_TEMP_DIR/routing-$tag"
  local fixture="$fixture_root/scripts/lbwc-routing.sh"
  mkdir -p "$fixture_root/templates/agent-roles"
  cp -R "$PROJECT_ROOT/scripts" "$fixture_root/scripts"
  cp "$ROUTING" "$fixture"
  rewrite_fixture_sources "$fixture" '
    /^  OD_TOOL=\$\(first_executable \/usr\/bin\/od \/bin\/od\)/ {
      print "  OD_TOOL=$(first_executable \"" od_path "\")"
      next
    }
    { print }
  ' -v od_path="$stub_dir/od"
  cp "$PROJECT_ROOT/templates/agent-roles/defaults.json" "$fixture_root/templates/agent-roles/defaults.json"
  chmod +x "$fixture"
  printf '%s\n' "$fixture"
}

run_operation() {
  local script="$1" operation="$2"
  shift 2
  case "$operation" in
    set) run env "$@" bash "$script" set "$PLANNING" balanced docs ember-path '"swift"' ;;
    copy) run env "$@" bash "$script" copy "$PLANNING" balanced turbo ;;
    activate) run env "$@" bash "$script" activate "$PLANNING" turbo ;;
    migrate) run env "$@" bash "$script" migrate "$PLANNING" ;;
  esac
}

expect_no_lock_files() {
  local label="$1"
  [ ! -e "$PLANNING/.routing.lock" ] || record_case_failure "$label" "lock directory remained"
  [ ! -e "$PLANNING/.routing.lock.guard" ] || record_case_failure "$label" "lock guard remained"
}

setup() {
  routing_fixture_setup
}

teardown() {
  routing_fixture_teardown
}

backend_row() {
  local label="$1" want_status="$2" want_output="$3"
  shift 3
  run bash "$BATS_TEST_DIRNAME/routing_lock_probe.bash" "$ROUTING" "$@"
  expect_case "$label" "$want_status"
  [ -z "$want_output" ] || [ "$output" = "$want_output" ] \
    || record_case_failure "$label" "expected output=[$want_output] got=[$output]"
}

@test "the real platform descriptor backend holds the guard for the owning shell lifetime" {
  local platform guard ready backend expected_backend
  platform=$(system_platform)
  case "$platform" in
    Darwin) expected_backend=/usr/bin/lockf ;;
    Linux)
      if [ -x /usr/bin/flock ]; then
        expected_backend=/usr/bin/flock
      else
        expected_backend=/bin/flock
      fi
      ;;
    *) skip "descriptor lock runtime is unsupported on $platform" ;;
  esac
  [ -x "$expected_backend" ]

  guard="$TEST_TEMP_DIR/platform.guard"
  ready="$TEST_TEMP_DIR/platform-owner-ready"
  backend="$TEST_TEMP_DIR/platform-backend"
  LOCK_OWNER_RELEASE="$TEST_TEMP_DIR/platform-owner-release"
  export LOCK_OWNER_RELEASE

  bash "$BATS_TEST_DIRNAME/routing_lock_probe.bash" "$ROUTING" \
    hold_platform_guard "$guard" "$backend" "$ready" "$LOCK_OWNER_RELEASE" &
  LOCK_OWNER_PID=$!
  export LOCK_OWNER_PID
  wait_for_file "$ready"

  [ "$(<"$backend")" = "$expected_backend" ]
  run bash "$BATS_TEST_DIRNAME/routing_lock_probe.bash" "$ROUTING" \
    hold_platform_guard "$guard"
  [ "$status" -ne 0 ]

  : > "$LOCK_OWNER_RELEASE"
  wait "$LOCK_OWNER_PID"
  unset LOCK_OWNER_PID
  run bash "$BATS_TEST_DIRNAME/routing_lock_probe.bash" "$ROUTING" \
    hold_platform_guard "$guard"
  [ "$status" -eq 0 ]
}

swap_lock_owner() {
  local lock="$PLANNING/.routing.lock"
  rm "$lock/owner"
  rmdir "$lock"
  mktemp -d "$TEST_TEMP_DIR/inode-hold.XXXXXX" >/dev/null
  mkdir "$lock"
  printf '%s\n' "$1" > "$lock/owner"
}

finish_recreated_lock() {
  local label="$1" writer_pid="$2" before="$3" planted="$4" writer_rc=0 lock="$PLANNING/.routing.lock"
  : > "$TEST_TEMP_DIR/release-first-transform"
  wait "$writer_pid" || writer_rc=$?
  [ "$writer_rc" -ne 0 ] || record_case_failure "$label" "writer succeeded against a recreated lock"
  expect_digest "$label" "$before" "$(config_digest)"
  [ -d "$lock" ] || record_case_failure "$label" "recreated lock directory was removed"
  [ "$(<"$lock/owner")" = "$planted" ] \
    || record_case_failure "$label" "recreated lock owner was rewritten"
}

forged_owner_row() {
  local before original created writer_pid planted
  restore_planning
  printf '%s\n' 'unset RANDOM' 'RANDOM=7' > "$TEST_TEMP_DIR/bash-env"
  before=$(config_digest)
  start_blocked_writer BASH_ENV="$TEST_TEMP_DIR/bash-env"
  writer_pid=$!
  original=$(<"$PLANNING/.routing.lock/owner")
  IFS=$'\t' read -r _ created _ <<< "$original"
  planted="$writer_pid"$'\t'"$created"$'\t'"$writer_pid-$created-7"
  swap_lock_owner "$planted"
  finish_recreated_lock forged-predictable-owner "$writer_pid" "$before" "$planted"
}

replayed_owner_row() {
  local before original writer_pid
  restore_planning
  before=$(config_digest)
  start_blocked_writer
  writer_pid=$!
  original=$(<"$PLANNING/.routing.lock/owner")
  swap_lock_owner "$original"
  finish_recreated_lock replayed-genuine-owner "$writer_pid" "$before" "$original"
}

@test "lock owners carry a 128-bit token, every resolution builds one, and forged or replayed owners are never trusted" {
  local lock="$PLANNING/.routing.lock" owner_record owner_pid created token writer_pid writer_rc=0 attempt failures=0
  install_blocking_jq
  snapshot_planning

  start_blocked_writer
  writer_pid=$!
  owner_record=$(<"$lock/owner")
  IFS=$'\t' read -r owner_pid created token <<< "$owner_record"
  : > "$TEST_TEMP_DIR/release-first-transform"
  wait "$writer_pid" || writer_rc=$?
  [ "$writer_rc" -eq 0 ] || record_case_failure owner-token-format "blocked writer exited $writer_rc"
  [ "$owner_pid" = "$writer_pid" ] || record_case_failure owner-token-format "owner pid=$owner_pid writer=$writer_pid"
  [[ "$created" =~ ^[1-9][0-9]*$ ]] || record_case_failure owner-token-format "created=$created"
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || record_case_failure owner-token-format "token=$token"

  restore_planning
  bash "$ROUTING" set "$PLANNING" balanced docs ember-path '"swift"' >/dev/null \
    || record_case_failure repeated-resolution "seed set failed"
  for ((attempt = 0; attempt < 100; attempt++)); do
    bash "$ROUTING" resolve "$PLANNING" docs >/dev/null 2>&1 \
      || failures=$((failures + 1))
  done
  [ "$failures" -eq 0 ] || record_case_failure repeated-resolution "$failures of 100 resolutions failed"

  forged_owner_row
  replayed_owner_row

  assert_no_case_failures
}

plant_live_owner() {
  sleep 30 &
  LIVE_OWNER_PID=$!
  mkdir "$PLANNING/.routing.lock"
  printf '%s\t%s\t%s\n' "$LIVE_OWNER_PID" "$(($(date +%s) - 120))" live-owner > "$PLANNING/.routing.lock/owner"
}

contention_row() {
  local label="$1" fragment="$2" expected_owner="$3" before
  before=$(config_digest)
  run_operation "$ROUTING" set LBWC_ROUTING_LOCK_WAIT_ATTEMPTS=3
  expect_rejected "$label" "$fragment"
  expect_digest "$label" "$before" "$(config_digest)"
  [ "$(<"$PLANNING/.routing.lock/owner")" = "$expected_owner" ] \
    || record_case_failure "$label" "lock owner record was changed"
}

@test "a lock the writer does not own is never reclaimed or removed, and a dead stale lock is reclaimed" {
  local owner_record writer_pid waiter_rc=0 dead_pid
  install_blocking_jq
  snapshot_planning

  plant_live_owner
  contention_row live-lock-times-out "could not acquire routing lock" \
    "$(<"$PLANNING/.routing.lock/owner")"
  kill -TERM "$LIVE_OWNER_PID"
  wait "$LIVE_OWNER_PID" 2>/dev/null || true
  restore_planning

  mkdir "$PLANNING/.routing.lock"
  printf '%s\n' 'not owner metadata' > "$PLANNING/.routing.lock/owner"
  contention_row malformed-lock-fails-closed "" 'not owner metadata'
  restore_planning

  mkdir "$PLANNING/.routing.lock"
  run_operation "$ROUTING" set LBWC_ROUTING_LOCK_WAIT_ATTEMPTS=3
  expect_rejected unowned-lock-never-reclaimed ""
  [ -d "$PLANNING/.routing.lock" ] || record_case_failure unowned-lock-never-reclaimed "lock directory was removed"
  restore_planning

  start_blocked_writer
  writer_pid=$!
  owner_record=$(<"$PLANNING/.routing.lock/owner")
  env LBWC_ROUTING_LOCK_WAIT_ATTEMPTS=3 \
    bash "$ROUTING" set "$PLANNING" balanced architect nova-route '"deliberate"' \
    >/dev/null 2>&1 || waiter_rc=$?
  [ "$waiter_rc" -ne 0 ] || record_case_failure waiter-cannot-take-live-lock "waiter succeeded"
  [ "$(<"$PLANNING/.routing.lock/owner")" = "$owner_record" ] \
    || record_case_failure waiter-cannot-take-live-lock "waiter rewrote the owner record"
  : > "$TEST_TEMP_DIR/release-first-transform"
  wait "$writer_pid"
  [ ! -e "$PLANNING/.routing.lock" ] \
    || record_case_failure owner-removes-its-own-lock "lock directory remained after the owner finished"

  restore_planning
  sleep 30 &
  dead_pid=$!
  kill -TERM "$dead_pid"
  wait "$dead_pid" 2>/dev/null || true
  mkdir "$PLANNING/.routing.lock"
  printf '%s\t%s\t%s\n' "$dead_pid" "$(($(date +%s) - 120))" "dead-owner" > "$PLANNING/.routing.lock/owner"
  run bash "$ROUTING" set "$PLANNING" balanced docs ember-path '"swift"'
  expect_case dead-stale-lock-reclaimed 0
  [ ! -e "$PLANNING/.routing.lock" ] || record_case_failure dead-stale-lock-reclaimed "stale lock remained"
  expect_jq dead-stale-lock-reclaimed "$PLANNING/config.json" '
    .routing.profiles.balanced.roles.docs
    == {model: "ember-path", reasoning: "swift", status: "resolved"}
  '

  assert_no_case_failures
}

od_ignored_row() {
  local label="$1" operation="$2" behavior="$3"
  local marker="$TEST_TEMP_DIR/od-$operation-$behavior-called"
  local wrapper_dir="$TEST_TEMP_DIR/bin"
  restore_planning
  mkdir -p "$wrapper_dir"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    ': > "$ROUTING_OD_CALLED"' \
    'case "$ROUTING_OD_BEHAVIOR" in' \
    '  short) printf '"'"'%s\n'"'"' '"'"'00112233445566778899aabbccddee'"'"' ;;' \
    '  failing) exit 1 ;;' \
    '  valid) printf '"'"'%s\n'"'"' '"'"'00112233445566778899aabbccddeeff'"'"' ;;' \
    'esac' > "$wrapper_dir/od"
  chmod +x "$wrapper_dir/od"

  run_operation "$ROUTING" "$operation" "PATH=$wrapper_dir:$PATH" \
    "ROUTING_OD_CALLED=$marker" "ROUTING_OD_BEHAVIOR=$behavior"

  expect_case "$label" 0
  [ ! -e "$marker" ] || record_case_failure "$label" "the PATH od program ran"
  [ ! -e "$PLANNING/.routing.lock" ] || record_case_failure "$label" "lock directory remained"
}

@test "lock backends follow the platform, entropy and od failures precede mutation, and od on PATH or a benign od warning is harmless" {
  local fake_tool="$TEST_TEMP_DIR/fake-lock-tool" operation behavior label mode fixture
  local entropy_text='could not create secure routing lock owner token: '
  printf '%s\n' '#!/usr/bin/env bash' 'printf '"'"'%s\n'"'"' "$*"' > "$fake_tool"
  chmod +x "$fake_tool"
  snapshot_planning

  backend_row darwin-uses-lockf 0 lockf lock_backend_for_system Darwin
  backend_row linux-uses-flock 0 flock lock_backend_for_system Linux
  backend_row lockf-arguments 0 '-s -t 0 9' invoke_lock_backend lockf "$fake_tool" 9
  backend_row flock-arguments 0 '-n 9' invoke_lock_backend flock "$fake_tool" 9
  run bash "$BATS_TEST_DIRNAME/routing_lock_probe.bash" "$ROUTING" lock_backend_for_system Windows
  [ "$status" -ne 0 ] || record_case_failure unsupported-system-fails "unexpected success output=$output"

  while IFS='|' read -r operation behavior; do
    [ -n "$operation" ] || continue
    od_ignored_row "$operation-$behavior" "$operation" "$behavior"
  done <<'CASES'
set|short
set|failing
set|valid
copy|short
copy|failing
copy|valid
activate|short
activate|failing
activate|valid
migrate|short
migrate|failing
migrate|valid
CASES

  while IFS='|' read -r label mode operation; do
    [ -n "$label" ] || continue
    failure_before_mutation_row "$label" "$mode" "$operation"
  done <<'CASES'
entropy-set|entropy|set
entropy-copy|entropy|copy
entropy-activate|entropy|activate
entropy-migrate|entropy|migrate
unsupported-platform|unsupported|set
missing-backend|missing|set
CASES

  restore_planning
  run_operation "$(create_routing_failure_fixture entropy)" set
  expect_fragment entropy-message "$entropy_text"
  expect_fragment entropy-message "exited 1"
  expect_fragment entropy-message "No such file or directory"

  od_failure_row silent-od silent "" ""
  expect_fragment silent-od "(no output captured)"

  od_failure_row labelled-od labelled ZZSTDOUTZZ ZZSTDERRZZ
  expect_fragment labelled-od "(od stdout: ZZSTDOUTZZ)"
  expect_fragment labelled-od "(captured stderr: ZZSTDERRZZ)"
  [[ "$output" != *"(od stdout: ZZSTDERRZZ)"* ]] \
    || record_case_failure labelled-od "stderr landed in the stdout field"
  [[ "$output" != *"(captured stderr: ZZSTDOUTZZ)"* ]] \
    || record_case_failure labelled-od "stdout landed in the stderr field"

  restore_planning
  write_od_stub "$TEST_TEMP_DIR/warn-bin" 00112233445566778899aabbccddeeff "'od: warning: benign notice'" 0
  fixture=$(create_od_fixture warn)
  run_operation "$fixture" set
  expect_case od-benign-warning 0
  expect_jq od-benign-warning "$PLANNING/config.json" '
    .routing.profiles.balanced.roles.docs
    == {model: "ember-path", reasoning: "swift", status: "resolved"}
  '

  assert_no_case_failures
}

failure_before_mutation_row() {
  local label="$1" mode="$2" operation="$3" fixture before
  restore_planning
  fixture=$(create_routing_failure_fixture "$mode")
  before=$(config_digest)

  run_operation "$fixture" "$operation"

  expect_rejected "$label" ""
  expect_digest "$label" "$before" "$(config_digest)"
  expect_no_lock_files "$label"
}

od_failure_row() {
  local label="$1" tag="$2" out="$3" err="$4" fixture before
  restore_planning
  write_od_stub "$TEST_TEMP_DIR/$tag-bin" "$out" "$err" 1
  fixture=$(create_od_fixture "$tag")
  before=$(config_digest)

  run_operation "$fixture" set

  expect_rejected "$label" "could not create secure routing lock owner token: "
  expect_fragment "$label" "exited 1"
  expect_digest "$label" "$before" "$(config_digest)"
  expect_no_lock_files "$label"
}
