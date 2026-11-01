#!/usr/bin/env bats

load test_helper
load gate_case_helper

setup() {
  setup_temp_dir
  export CLAUDE_SESSION_ID="covw2-persist-$$-$BATS_TEST_NUMBER"
  SESSION_LINK="/tmp/.lbwc-plugin-root-link-$CLAUDE_SESSION_ID"
  cd "$TEST_TEMP_DIR"
  reset_case_failures
}

teardown() {
  cd "$PROJECT_ROOT"
  rm -f "$SESSION_LINK"
  teardown_temp_dir
}

root_state_from() {
  printf '%s\n' "$@" > archived-STATE.md
  bash "$SCRIPTS_DIR/persist-state-after-ship.sh" archived-STATE.md out/STATE.md "Acme" || return
  cat out/STATE.md
}

@test "ship persistence rejects missing arguments and a missing archived state" {
  run bash "$SCRIPTS_DIR/persist-state-after-ship.sh" archived.md out/STATE.md
  expect_case two-arguments 1 "Usage"

  run bash "$SCRIPTS_DIR/persist-state-after-ship.sh" absent.md out/STATE.md Acme
  expect_case missing-archive 1 "absent.md"

  assert_no_case_failures
}

@test "ship persistence carries decisions, todos, blockers, and codebase profile into a fresh root state" {
  run root_state_from '# State' '## Current Phase' 'Phase 3 active'
  expect_case empty-sections 0 "**Project:** Acme"
  expect_case empty-sections 0 "| _(No decisions yet)_ | | |"
  expect_case empty-sections 0 $'## Todos\nNone.'
  expect_case empty-sections 0 $'## Blockers\nNone'
  expect_case_absent empty-sections "Phase 3 active"
  expect_case_absent empty-sections "Codebase Profile"

  run root_state_from '# State' '## Key Decisions' '| Decision | Date | Rationale |' '|---|---|---|' \
    '| Use jq | | |' '| Use jq | 2026-01-01 | Fast parsing |' '| Use jq | | |' '- Use bats' '- **use  bats**' '- Split a|b' '- None' \
    '### Skills' '- skill-only row' '### Notes' '- Note decision'
  expect_case table-and-bullet-decisions 0 "| Use jq | 2026-01-01 | Fast parsing |"
  expect_case table-and-bullet-decisions 0 "| Use bats | | |"
  expect_case table-and-bullet-decisions 0 "| Split a\\|b | | |"
  expect_case table-and-bullet-decisions 0 "| Note decision | | |"
  expect_case_absent table-and-bullet-decisions "| Use jq | | |"
  expect_case_absent table-and-bullet-decisions "use  bats"
  expect_case_absent table-and-bullet-decisions "skill-only row"

  run root_state_from '# State' '## Decisions' '- None.' '- _(No decisions yet)_'
  expect_case only-placeholder-decisions 0 "| _(No decisions yet)_ | | |"

  run root_state_from '# State' '## Decisions' '- Pick A' '### Pending Todos' '- Write docs' '### Later' '## Activity Log' '- shipped'
  expect_case pending-todos-inside-decisions 0 "| Pick A | | |"
  expect_case pending-todos-inside-decisions 0 $'## Todos\n- Write docs'
  expect_case_absent pending-todos-inside-decisions "Write docs |"
  expect_case_absent pending-todos-inside-decisions "- shipped"

  run root_state_from '# State' '## Todos' '- None.' '' '## Blockers' '' '## Codebase Profile' 'None.'
  expect_case placeholder-todos 0 $'## Todos\nNone.'
  expect_case placeholder-todos 0 $'## Blockers\nNone'
  expect_case_absent placeholder-todos "Codebase Profile"

  run root_state_from '# State' '## TODOS' '- Ship docs' '## Blockers' '- Waiting on API key' '## Codebase Profile' 'Bash 3.2 scripts' '## Activity Log' '- done'
  expect_case kept-sections 0 $'## Todos\n- Ship docs'
  expect_case kept-sections 0 $'## Blockers\n- Waiting on API key'
  expect_case kept-sections 0 $'## Codebase Profile\nBash 3.2 scripts'
  expect_case_absent kept-sections "- done"

  assert_no_case_failures
}

@test "ship persistence asks the session todo-details helper to collect stale details" {
  local plugin="$TEST_TEMP_DIR/plugin"
  mkdir -p "$plugin/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" > "$(dirname "$2")/gc-call"' > "$plugin/scripts/todo-details.sh"
  ln -sn "$plugin" "$SESSION_LINK"
  printf '%s\n' '# State' '## Todos' '- Ship docs' > archived-STATE.md

  bash "$SCRIPTS_DIR/persist-state-after-ship.sh" archived-STATE.md out/STATE.md Acme
  run cat out/gc-call
  [ "$status" -eq 0 ]
  [ "$output" = "gc out/STATE.md out/todo-details.json" ]
}
