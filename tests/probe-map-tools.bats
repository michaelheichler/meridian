#!/usr/bin/env bats

load test_helper
load gate_case_helper
load gate_case_files

setup() {
  setup_temp_dir
  unset CLAUDE_CONFIG_DIR
  PROJECT_DIR="$TEST_TEMP_DIR/project"
  mkdir -p "$PROJECT_DIR"
  cd "$PROJECT_DIR"
  git init --quiet
  git config user.email "test@test.com"
  git config user.name "Test"
  touch dummy && git add dummy && git commit -m "init" --quiet
  stub_bash_language_server
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  await_git_ai
  teardown_temp_dir
}

reset_row() {
  rm -rf "$HOME/.claude" "$HOME/.claude.json" "$PROJECT_DIR/.mcp.json" "$PROJECT_DIR/.lbwc-planning" "$PROJECT_DIR/.gitnexus" "$PROJECT_DIR/probe.sh"
}

serena_enabled() {
  mkdir -p "$HOME/.claude"
  printf '%s' '{"enabledPlugins":{"serena@claude-plugins-official":true}}' > "$HOME/.claude/settings.json"
}

serena_absent() {
  mkdir -p "$HOME/.claude"
  printf '%s' '{"enabledPlugins":{}}' > "$HOME/.claude/settings.json"
}

gitnexus_global() {
  printf '%s' '{"mcpServers":{"gitnexus":{"command":"/opt/homebrew/bin/gitnexus","args":["mcp"]}}}' > "$HOME/.claude.json"
}

gitnexus_absent() {
  printf '%s' '{"mcpServers":{}}' > "$HOME/.claude.json"
}

lsp_enabled() {
  mkdir -p "$HOME/.claude"
  printf '%s' '{"enabledPlugins":{},"env":{"ENABLE_LSP_TOOL":"1"}}' > "$HOME/.claude/settings.json"
  echo '#!/usr/bin/env bash' > "$PROJECT_DIR/probe.sh"
}

stub_bash_language_server() {
  mkdir -p "$TEST_TEMP_DIR/bin"
  printf '%s\n' '#!/bin/sh' 'echo 1.0.0' > "$TEST_TEMP_DIR/bin/bash-language-server"
  chmod +x "$TEST_TEMP_DIR/bin/bash-language-server"
  PATH="$TEST_TEMP_DIR/bin:$PATH"
}

run_probe() {
  run bash "$SCRIPTS_DIR/probe-map-tools.sh"
}

expect_map() {
  local label=$1 filter=$2
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1 \
    || record_case_failure "$label" "not a SessionStart hook payload: $output"
  printf '%s' "$output" | jq -e ".hookSpecificOutput.additionalContext | fromjson | $filter" >/dev/null 2>&1 \
    || record_case_failure "$label" "map filter failed=[$filter] output=$output"
}

@test "probe-map-tools route: prefers serena, then gitnexus, then lsp, then grep-only, and finds gitnexus in every config scope" {
  serena_enabled
  gitnexus_global
  run_probe
  expect_status serena-and-gitnexus 0
  expect_map serena-and-gitnexus '.serena.available == true and .gitnexus.available == true and .recommended_route == "serena"'

  reset_row
  serena_absent
  gitnexus_global
  run_probe
  expect_status gitnexus-only 0
  expect_map gitnexus-only '.serena.available == false and .gitnexus.available == true and .recommended_route == "gitnexus"'

  reset_row
  serena_absent
  gitnexus_absent
  lsp_enabled
  run_probe
  expect_status lsp-only 0
  expect_map lsp-only '.serena.available == false and .gitnexus.available == false and .lsp.env_needed == false and .recommended_route == "lsp"'

  reset_row
  serena_absent
  gitnexus_absent
  run_probe
  expect_status grep-only 0
  expect_map grep-only '.serena.available == false and .gitnexus.available == false and .recommended_route == "grep-only"'

  reset_row
  run_probe
  expect_status nothing-configured 0
  expect_map nothing-configured '.recommended_route == "grep-only" and (.serena.reason | endswith("settings.json not found"))'

  reset_row
  serena_absent
  printf '%s' '{"mcpServers":{"gitnexus":{"command":"gitnexus"}}}' > "$PROJECT_DIR/.mcp.json"
  run_probe
  expect_status project-mcp-file 0
  expect_map project-mcp-file '.gitnexus.available == true and (.gitnexus.reason | contains(".mcp.json"))'

  reset_row
  serena_absent
  jq -n --arg project "$PROJECT_DIR" '{projects:{($project):{mcpServers:{gitnexus:{command:"gitnexus"}}}}}' > "$HOME/.claude.json"
  run_probe
  expect_status per-project-config 0
  expect_map per-project-config '.gitnexus.available == true and (.gitnexus.reason | contains("projects"))'

  reset_row
  serena_absent
  gitnexus_global
  run_probe
  expect_status global-config 0
  expect_map global-config '.gitnexus.available == true and (.gitnexus.reason | contains("global scope"))'

  reset_row
  serena_absent
  gitnexus_absent
  mkdir -p "$PROJECT_DIR/.gitnexus"
  run_probe
  expect_status indexed-flag 0
  expect_map indexed-flag '.gitnexus.available == false and .gitnexus.indexed == true'

  assert_no_case_failures
}

@test "probe-map-tools state: reports the codebase map, persists only into an existing planning directory, and reports a missing jq" {
  local current_hash digest map_dir bash_bin empty_path

  serena_absent
  gitnexus_absent
  run_probe
  expect_status no-planning 0
  expect_no_path no-planning "$PROJECT_DIR/.lbwc-planning"
  expect_map no-planning '.codebase_map.available == false and .codebase_map.canonical_path == null'

  reset_row
  serena_absent
  gitnexus_absent
  mkdir -p "$PROJECT_DIR/.lbwc-planning"
  run_probe
  expect_status persisted 0
  expect_jq persisted "$PROJECT_DIR/.lbwc-planning/MAP-TOOLS.json" '.recommended_route == "grep-only"'

  reset_row
  serena_absent
  gitnexus_absent
  map_dir="$PROJECT_DIR/.lbwc-planning/codebase"
  mkdir -p "$map_dir"
  current_hash=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  printf 'mapped_at: 2026-08-01T00:00:00Z\ngit_hash: %s\nfile_count: 1\n' "$current_hash" > "$map_dir/META.md"
  digest=$(shasum -a 256 "$map_dir/META.md" | awk '{print "sha256:" $1}')
  run_probe
  expect_status map-fresh 0
  expect_map map-fresh ".codebase_map == {available:true,canonical_path:\"$(cd "$map_dir" && pwd -P)/META.md\",digest:\"$digest\",freshness:\"fresh\"}"

  printf 'mapped_at: 2026-08-01T00:00:00Z\ngit_hash: %s\nfile_count: 1\n' "0000000000000000000000000000000000000000" > "$map_dir/META.md"
  run_probe
  expect_status map-other-commit 0
  expect_map map-other-commit '.codebase_map.freshness == "stale"'

  printf 'mapped_at: 2026-08-01T00:00:00Z\ngit_hash: %s\nfile_count: 0\n' "$current_hash" > "$map_dir/META.md"
  run_probe
  expect_status map-zero-files 0
  expect_map map-zero-files '.codebase_map.freshness == "stale"'

  reset_row
  bash_bin=$(command -v bash)
  empty_path="$TEST_TEMP_DIR/empty-path"
  mkdir -p "$empty_path"
  run env PATH="$empty_path" "$bash_bin" "$SCRIPTS_DIR/probe-map-tools.sh"
  expect_case jq-missing 0 "jq is required but not installed"
  expect_output_has jq-missing "SessionStart"

  assert_no_case_failures
}
