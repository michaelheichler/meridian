#!/usr/bin/env bats

load test_helper

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  COMMAND="$REPO_ROOT/commands/transit.md"
}

@test "transit command allows Workflow in frontmatter" {
  grep -E '^allowed-tools:.*\bWorkflow\b' "$COMMAND"
}
