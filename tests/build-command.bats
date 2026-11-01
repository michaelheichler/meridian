#!/usr/bin/env bats

load test_helper

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  COMMAND="$REPO_ROOT/commands/build.md"
}

@test "build command allows Workflow and AskUserQuestion in frontmatter" {
  grep -E '^allowed-tools:.*\bWorkflow\b' "$COMMAND"
  grep -E '^allowed-tools:.*\bAskUserQuestion\b' "$COMMAND"
}
