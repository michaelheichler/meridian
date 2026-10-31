#!/usr/bin/env bats

load test_helper

bats_require_minimum_version 1.5.0

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

run_filter() {
  local file_path="$1"
  payload "tool_input.file_path=$file_path" | bash "$SCRIPTS_DIR/security-filter.sh"
}

@test "allows a normal source file" {
  run run_filter "src/main.py"
  [ "$status" -eq 0 ]
}

@test "blocks .env files" {
  run run_filter ".env"
  [ "$status" -eq 2 ]
}

@test "blocks a bare .pem file" {
  run run_filter "id_rsa.pem"
  [ "$status" -eq 2 ]
}

@test "blocks a .pem file with a trailing extra extension" {
  run run_filter "id_rsa.pem.orig"
  [ "$status" -eq 2 ]
}

@test "blocks a .pem-named directory even when the leaf file is harmless" {
  run run_filter "vendor.pem/notes.txt"
  [ "$status" -eq 2 ]
}

@test "does not block a filename that merely contains pem without a dot" {
  run run_filter "openpem/notes.txt"
  [ "$status" -eq 0 ]
}

@test "blocks node_modules paths" {
  run run_filter "node_modules/leftpad/index.js"
  [ "$status" -eq 2 ]
}

@test "blocks empty file path" {
  run run_filter ""
  [ "$status" -eq 2 ]
}

@test "allows a Grep call with no path field, regex is not a path" {
  local json
  json=$(payload "tool_input.pattern=dist/|build/")
  run bash -c "printf '%s' '$json' | bash '$SCRIPTS_DIR/security-filter.sh'"
  [ "$status" -eq 0 ]
}

@test "does not block a search whose pattern contains dist/ or build/ when a real path is also present" {
  local json
  json=$(payload "tool_input.pattern=dist/|build/" "tool_input.path=src")
  run bash -c "printf '%s' '$json' | bash '$SCRIPTS_DIR/security-filter.sh'"
  [ "$status" -eq 0 ]
}

run_tool_filter() {
  local tool_name="$1" path_key="$2" target="$3"
  payload "tool_name=$tool_name" "tool_input.$path_key=$target" | bash "$SCRIPTS_DIR/security-filter.sh"
}

assert_tool_exit() {
  local expected="$1" tool_name="$2" path_key="$3" target="$4"
  run run_tool_filter "$tool_name" "$path_key" "$target"
  [ "$status" -eq "$expected" ]
}

for target in build/x dist/y; do
  bats_test_function --description "Read of $target is allowed" -- assert_tool_exit 0 Read file_path "$target"
  bats_test_function --description "Grep of $target is allowed" -- assert_tool_exit 0 Grep path "$target"
  bats_test_function --description "Write of $target is blocked" -- assert_tool_exit 2 Write file_path "$target"
  bats_test_function --description "Edit of $target is blocked" -- assert_tool_exit 2 Edit file_path "$target"
done

bats_test_function --description "Read of .env stays blocked" -- assert_tool_exit 2 Read file_path .env
bats_test_function --description "Grep of .env stays blocked" -- assert_tool_exit 2 Grep path .env

@test "allows the call and warns on stderr when jq is missing" {
  local no_jq_bin="$TEST_TEMP_DIR/no-jq-bin"
  mkdir -p "$no_jq_bin"
  local json
  json=$(payload "tool_name=Write" "tool_input.file_path=.env")

  run --separate-stderr env PATH="$no_jq_bin" "$BASH" -c 'printf "%s" "$1" | "$BASH" "$2"' _ "$json" "$SCRIPTS_DIR/security-filter.sh"

  [ "$status" -eq 0 ]
  [ "$stderr" = "meridian hook warning: security-filter jq not available, call allowed" ]
}
