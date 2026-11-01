#!/usr/bin/env bats

load test_helper
load gate_case_helper
load rejection_case_helper

bats_require_minimum_version 1.5.0

setup() {
  setup_temp_dir
  cd "$TEST_TEMP_DIR"
}

teardown() {
  cd "$PROJECT_ROOT"
  teardown_temp_dir
}

tree_digest() {
  find "$TEST_TEMP_DIR" | sort
}

feed_filter() {
  printf '%s' "$1" | bash "$SCRIPTS_DIR/security-filter.sh"
}

allow_row() {
  local label="$1" tool_name="$2" path_key="$3" target="$4" before
  before=$(tree_digest)
  run feed_filter "$(payload "tool_name=$tool_name" "tool_input.$path_key=$target")"
  expect_case_silent "$label" 0
  expect_digest "$label" "$before" "$(tree_digest)"
}

deny_row() {
  local label="$1" tool_name="$2" path_key="$3" target="$4"
  run feed_filter "$(payload "tool_name=$tool_name" "tool_input.$path_key=$target")"
  expect_case "$label" 2 "Blocked: sensitive file ($target)"
}

@test "allow rows let ordinary paths, search patterns and build output reads through silently" {
  reset_case_failures

  allow_row normal-source-file Write file_path src/main.py
  allow_row pem-without-dot-in-name Write file_path openpem/notes.txt
  allow_row grep-pattern-without-path Grep pattern 'dist/|build/'
  allow_row read-build-dir Read file_path build/x
  allow_row read-dist-dir Read file_path dist/y
  allow_row grep-build-dir Grep path build/x
  allow_row grep-dist-dir Grep path dist/y

  local before
  before=$(tree_digest)
  run feed_filter "$(payload "tool_input.pattern=dist/|build/" "tool_input.path=src")"
  expect_case_silent pattern-with-dist-and-real-path 0
  expect_digest pattern-with-dist-and-real-path "$before" "$(tree_digest)"

  assert_no_case_failures
}

@test "deny rows block sensitive paths with exit 2 and name the path" {
  reset_case_failures

  deny_row env-file Write file_path .env
  deny_row env-variant Write file_path config/.env.production
  deny_row bare-pem Write file_path id_rsa.pem
  deny_row pem-with-extra-extension Write file_path id_rsa.pem.orig
  deny_row pem-named-directory Write file_path vendor.pem/notes.txt
  deny_row key-file Write file_path certs/server.key
  deny_row cert-file Write file_path certs/server.cert
  deny_row p12-file Write file_path certs/client.p12
  deny_row pfx-file Write file_path certs/client.pfx
  deny_row credentials-json Write file_path config/credentials.json
  deny_row secrets-json Write file_path config/secrets.json
  deny_row service-account-json Write file_path gcp/service-account-prod.json
  deny_row node-modules Write file_path node_modules/leftpad/index.js
  deny_row git-directory Write file_path .git/config
  deny_row temporary-agent-runfiles Write file_path .temporary-agent-runfiles/state.json
  deny_row write-build-dir Write file_path build/x
  deny_row write-dist-dir Write file_path dist/y
  deny_row edit-build-dir Edit file_path build/x
  deny_row edit-dist-dir Edit file_path dist/y
  deny_row read-env-file Read file_path .env
  deny_row grep-env-file Grep path .env
  deny_row read-node-modules Read file_path node_modules/pkg/index.js

  assert_no_case_failures
}

@test "deny rows fail closed with exit 2 on an empty path or unreadable input" {
  reset_case_failures

  run feed_filter "$(payload "tool_input.file_path=")"
  expect_case_silent empty-file-path 2

  run feed_filter ""
  expect_case_silent empty-input 2

  run feed_filter "not json{{{"
  expect_case_silent malformed-json 2

  assert_no_case_failures
}

@test "allows the call and warns on stderr when jq is missing" {
  local no_jq_bin="$TEST_TEMP_DIR/no-jq-bin"
  mkdir -p "$no_jq_bin"
  local json
  json=$(payload "tool_name=Write" "tool_input.file_path=.env")

  run --separate-stderr env PATH="$no_jq_bin" "$BASH" -c 'printf "%s" "$1" | "$BASH" "$2"' _ "$json" "$SCRIPTS_DIR/security-filter.sh"

  [ "$status" -eq 0 ]
  [ "$stderr" = "meridian hook warning: security-filter jq not available, call allowed" ]
}
