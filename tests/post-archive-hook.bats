#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  PROJECT="$TEST_TEMP_DIR/project"
  mkdir -p "$PROJECT/.meridian" "$PROJECT/hooks"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "hook-args=%s|%s|%s|%s\n" "$1" "$2" "$3" "$(pwd -P)"' > "$PROJECT/hooks/archive.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "$PROJECT/hooks/broken.sh"
  PROJECT_REAL=$(CDPATH='' cd -- "$PROJECT" && pwd -P)
  cd "$PROJECT"
  export MERIDIAN_CONFIG_ROOT="$PROJECT"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  unset MERIDIAN_CONFIG_ROOT
  teardown_temp_dir
}

config() {
  printf '%s\n' "$1" > .meridian/config.json
}

archive_hook() {
  run bash "$SCRIPTS_DIR/post-archive-hook.sh" "$@"
}

@test "post-archive dispatcher runs the configured hook from the project root and fails open" {
  local archive="$PROJECT_REAL/.meridian/milestones/v1-auth"

  config '{"hooks":{"post_archive":"hooks/archive.sh"}}'
  archive_hook "" .meridian/milestones/v1-auth milestone/v1-auth .meridian/config.json
  expect_case_silent missing-slug 0

  archive_hook v1-auth "" milestone/v1-auth .meridian/config.json
  expect_case_silent missing-archive-path 0

  archive_hook v1-auth .meridian/milestones/v1-auth milestone/v1-auth .meridian/config.json
  expect_case relative-hook 0 "hook-args=v1-auth|$archive|milestone/v1-auth|$PROJECT_REAL"

  archive_hook v1-auth .meridian/milestones/v1-auth "" "$PROJECT/.meridian/config.json"
  expect_case no-tag-absolute-config 0 "hook-args=v1-auth|$archive||$PROJECT_REAL"

  archive_hook v1-auth .meridian/milestones/v1-auth milestone/v1-auth
  expect_case default-config-path 0 "hook-args=v1-auth|$archive|milestone/v1-auth|$PROJECT_REAL"

  archive_hook v1-auth .meridian/milestones/v1-auth milestone/v1-auth "$TEST_TEMP_DIR/absent/config.json"
  expect_case missing-config 0 "config not found"

  mkdir -p "$TEST_TEMP_DIR/no-jq-bin"
  ln -s "$(command -v dirname)" "$TEST_TEMP_DIR/no-jq-bin/dirname"
  ln -s "$(command -v basename)" "$TEST_TEMP_DIR/no-jq-bin/basename"
  run env PATH="$TEST_TEMP_DIR/no-jq-bin" "$(command -v bash)" "$SCRIPTS_DIR/post-archive-hook.sh" \
    v1-auth .meridian/milestones/v1-auth milestone/v1-auth .meridian/config.json
  expect_case jq-unavailable 0 "jq"
  expect_case_absent jq-unavailable "hook-args="

  config '{}'
  archive_hook v1-auth .meridian/milestones/v1-auth milestone/v1-auth .meridian/config.json
  expect_case_silent no-hook-configured 0

  config '{not json'
  archive_hook v1-auth .meridian/milestones/v1-auth milestone/v1-auth .meridian/config.json
  expect_case unreadable-config 0 "could not read hooks.post_archive"

  config "{\"hooks\":{\"post_archive\":\"$PROJECT/hooks/absent.sh\"}}"
  archive_hook v1-auth .meridian/milestones/v1-auth milestone/v1-auth .meridian/config.json
  expect_case hook-file-missing 0 "hooks/absent.sh"

  config '{"hooks":{"post_archive":"hooks/broken.sh"}}'
  archive_hook v1-auth .meridian/milestones/v1-auth milestone/v1-auth .meridian/config.json
  expect_case failing-hook 0 "hooks/broken.sh"

  assert_no_case_failures
}
