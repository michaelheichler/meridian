#!/usr/bin/env bats

load test_helper

OLD_BASH=/bin/bash
BASH32_ERROR_PATTERN='invalid option|bad substitution|syntax error'

setup() {
  setup_temp_dir
}

teardown() {
  teardown_temp_dir
}

skip_unless_old_bash() {
  local major
  major=$("$OLD_BASH" -c 'printf %s "${BASH_VERSINFO[0]}"')
  [ "$major" = 3 ] || skip "$OLD_BASH is not bash 3.x"
}

unguarded_entry_scripts() {
  local script
  while IFS= read -r script; do
    grep -q require_bash_43 "$script" || printf '%s\n' "$script"
  done < <(find "$SCRIPTS_DIR" -maxdepth 1 -name '*.sh' | sort)
}

bash32_offenders() {
  local script stderr_text status
  cd "$TEST_TEMP_DIR" || return 1
  while IFS= read -r script; do
    stderr_text=$("$OLD_BASH" "$script" --help 2>&1 >/dev/null </dev/null)
    status=$?
    if [[ "$stderr_text" =~ $BASH32_ERROR_PATTERN ]]; then
      printf '%s (exit %s): %s\n' "$(basename "$script")" "$status" "$(printf '%s' "$stderr_text" | head -n 1)"
    fi
  done < <(unguarded_entry_scripts)
}

@test "every unguarded entry script parses and starts under bash 3.2" {
  skip_unless_old_bash
  run bash32_offenders
  [ -z "$output" ]
}
