#!/usr/bin/env bats

load gate_case_helper
load gate_case_files

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HELP_OUTPUT="$REPO_ROOT/scripts/help-output.sh"
  TEST_ROOT="$(mktemp -d)"
  PLUGIN_ROOT="$TEST_ROOT/plugin"
  mkdir -p "$PLUGIN_ROOT/.claude-plugin" "$PLUGIN_ROOT/commands"
  jq -n '{name: "lbwc", version: "test"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  cat > "$PLUGIN_ROOT/commands/vibe.md" <<'EOF'
---
category: lifecycle
description: Continue the project workflow.
argument-hint: '[brief]'
allowed-tools: Read
disable-model-invocation: true
---
EOF
  cat > "$PLUGIN_ROOT/commands/list-todos.md" <<'EOF'
---
category: supporting
description: List project todos.
argument-hint: ''
allowed-tools: Read
disable-model-invocation: true
---
EOF
  reset_case_failures
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "help-output: derives names from the plugin manifest and filenames and groups commands by category" {
  run bash "$HELP_OUTPUT" "$PLUGIN_ROOT"
  expect_case manifest-and-filenames 0 "/lbwc:vibe '[brief]'"
  expect_output_has manifest-and-filenames '/lbwc:list-todos'
  expect_output_lacks manifest-and-filenames '/lbwc:lbwc:vibe'
  [ "$(printf '%s\n' "$output" | grep -c '^  /lbwc:vibe ')" -eq 1 ] \
    || record_case_failure manifest-and-filenames "vibe is not listed exactly once"
  [[ "$output" == *"Lifecycle, "*"Supporting, "* ]] || record_case_failure category-order "lifecycle must precede supporting output=$output"
  expect_output_lacks empty-sections "Advanced, "
  expect_output_lacks no-version-header ", v"

  cat > "$PLUGIN_ROOT/commands/secret.md" <<'EOF'
---
category: advanced
description: Not for the help list.
hidden: true
---
EOF
  cat > "$PLUGIN_ROOT/commands/misc.md" <<'EOF'
---
description: Has no category.
---
EOF
  printf '9.9.9\n' > "$PLUGIN_ROOT/VERSION"
  run bash "$HELP_OUTPUT" "$PLUGIN_ROOT"
  expect_case hidden-uncategorized-and-version 0 "/lbwc:misc"
  expect_output_has hidden-uncategorized-and-version "Other, Uncategorized"
  expect_output_has hidden-uncategorized-and-version "LBWC Help, v9.9.9"
  expect_output_lacks hidden-command-skipped "/lbwc:secret"
  expect_output_lacks hidden-command-section "Advanced, "

  assert_no_case_failures
}

@test "help-output: exits 1 with a warning when the commands, manifest or manifest name is missing" {
  mv "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/commands-away"
  run bash "$HELP_OUTPUT" "$PLUGIN_ROOT"
  expect_case missing-commands-dir 1 "Commands directory not found"
  mv "$PLUGIN_ROOT/commands-away" "$PLUGIN_ROOT/commands"

  printf '%s\n' '{"version":"test"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  run bash "$HELP_OUTPUT" "$PLUGIN_ROOT"
  expect_case manifest-without-name 1 "Plugin manifest has no valid name"

  rm "$PLUGIN_ROOT/.claude-plugin/plugin.json"
  run bash "$HELP_OUTPUT" "$PLUGIN_ROOT"
  expect_case missing-manifest 1 "Plugin manifest not found"

  assert_no_case_failures
}
