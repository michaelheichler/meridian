#!/usr/bin/env bats

load test_helper

OLD_BASH=/bin/bash
GUARD_LIB="$SCRIPTS_DIR/lib/require-bash.sh"

skip_unless_old_bash() {
  local major
  major=$("$OLD_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"')
  [ "$major" = 3 ] || skip "$OLD_BASH is not bash 3.x"
}

run_help_under_old_bash() {
  skip_unless_old_bash
  run "$OLD_BASH" "$SCRIPTS_DIR/$1" --help
}

@test "agent-generator refuses to run under bash 3.2 with a version message" {
  run_help_under_old_bash agent-generator.sh
  [ "$status" -eq 3 ]
  [[ "$output" == "meridian requires bash 4.3 or newer, found 3."* ]]
}

@test "tmux-spawn-group refuses to run under bash 3.2 with a version message" {
  run_help_under_old_bash tmux-spawn-group.sh
  [ "$status" -eq 3 ]
  [[ "$output" == "meridian requires bash 4.3 or newer, found 3."* ]]
}

@test "workflow-generator refuses to run under bash 3.2 with a version message" {
  run_help_under_old_bash workflow-generator.sh
  [ "$status" -eq 3 ]
  [[ "$output" == "meridian requires bash 4.3 or newer, found 3."* ]]
}

@test "render-agent-template refuses to run under bash 3.2 with a version message" {
  run_help_under_old_bash render-agent-template.sh
  [ "$status" -eq 3 ]
  [[ "$output" == "meridian requires bash 4.3 or newer, found 3."* ]]
}

@test "render-workflow-template refuses to run under bash 3.2 with a version message" {
  run_help_under_old_bash render-workflow-template.sh
  [ "$status" -eq 3 ]
  [[ "$output" == "meridian requires bash 4.3 or newer, found 3."* ]]
}

@test "sourcing verification-freshness under bash 3.2 exits with the version message" {
  skip_unless_old_bash
  run "$OLD_BASH" -c '. "$1"' _ "$SCRIPTS_DIR/verification-freshness.sh"
  [ "$status" -eq 3 ]
  [[ "$output" == "meridian requires bash 4.3 or newer, found 3."* ]]
}

@test "the guard passes silently on a bash that is new enough" {
  run bash -c '. "$1"; require_bash_43' _ "$GUARD_LIB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sourcing the guard leaves a caller with nounset off still off" {
  run bash -c 'set +u; . "$1"; [[ $- != *u* ]]' _ "$GUARD_LIB"
  [ "$status" -eq 0 ]
}
