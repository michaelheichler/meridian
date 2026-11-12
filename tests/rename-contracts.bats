#!/usr/bin/env bats

load test_helper
load gate_case_helper
load isolated_case_helper
load rename_cases

setup() {
  export RENAME_SHELL="${RENAME_TEST_BASH:-bash}"
  export RENAME_FIXTURE="$BATS_TEST_DIRNAME/rename_fixture.py"
  export RENAME_LIBRARY="$SCRIPTS_DIR/lib/rename-migration.sh"
}

teardown() {
  chmod u+w "$BATS_TEST_TMPDIR/repo" 2>/dev/null || true
  await_git_ai
}

@test "planning migration preserves complete state and becomes a silent no-op" {
  run_scenario_cases migration_old_only migration_both migration_new_only \
    migration_neither migration_repeated
}

@test "migration refuses unsafe destinations and preserves data on move failure" {
  run_scenario_cases migration_destination_file migration_destination_symlink \
    migration_source_symlink migration_unwritable
}

@test "Bash and Python legacy overrides fill only absent current values without chatter" {
  run_scenario_cases environment_unset environment_current environment_empty \
    environment_legacy_empty environment_no_legacy
}

@test "rename preview reports map changes without writing or counting protected content" {
  run_scenario_cases preview_command preview_boundaries preview_keeps preview_path \
    preview_excluded preview_binary preview_migration_block
}
