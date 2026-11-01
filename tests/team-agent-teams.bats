#!/usr/bin/env bats

load test_helper

ENABLED_MESSAGE='TEAM CHECK IS ENABLED. MOVE TO THE NEXT CHECK.'
DISABLED_MESSAGE='TEAM CHECK IS NOT ENABLED.'

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO_ROOT/scripts/lbwc-config.sh"
  TEST_ROOT="$(mktemp -d)"
  SETTINGS="$TEST_ROOT/settings.json"
  PROJECT="$TEST_ROOT/project"
  mkdir -p "$PROJECT/src" "$TEST_ROOT/claude"
  (cd "$PROJECT" && git init -q)
  export LBWC_SETTINGS_PATH="$SETTINGS"
  export CLAUDE_CONFIG_DIR="$TEST_ROOT/claude"
  unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS || true
  use_claude_fixture "$TEST_ROOT/host-claude"
  reset_settings
}

teardown() {
  rm -rf "$TEST_ROOT" 2>/dev/null || { sleep 1; rm -rf "$TEST_ROOT" 2>/dev/null || true; }
}

reset_settings() {
  rm -rf "$PROJECT/.claude" "$TEST_ROOT/claude"
  mkdir -p "$PROJECT/.claude" "$TEST_ROOT/claude"
  printf '%s\n' '{}' > "$SETTINGS"
}

write_teams_flag() {
  jq -n --arg value "$2" '{env:{CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:$value}}' > "$1"
}

seed_check_case() {
  reset_settings
  CHECK_ARGS=(--project-root "$PROJECT")
  case "$1" in
    omitted-flag) CHECK_ARGS=(--settings "$SETTINGS") ;;
    user-settings)
      write_teams_flag "$SETTINGS" 1
      CHECK_ARGS=(--settings "$SETTINGS")
      ;;
    project-settings) write_teams_flag "$PROJECT/.claude/settings.json" 1 ;;
    explicit-pin-beats-project)
      write_teams_flag "$PROJECT/.claude/settings.json" 1
      CHECK_ARGS=(--settings "$SETTINGS" --project-root "$PROJECT")
      ;;
    project-disable-beats-user)
      write_teams_flag "$TEST_ROOT/claude/settings.json" 1
      write_teams_flag "$PROJECT/.claude/settings.json" 0
      ;;
    corrupt-sibling-skipped)
      printf '%s\n' 'not-json' > "$PROJECT/.claude/settings.local.json"
      write_teams_flag "$PROJECT/.claude/settings.json" 1
      ;;
    *) return 1 ;;
  esac
}

seed_directive_case() {
  reset_settings
  [ "$1" = enabled ] && write_teams_flag "$TEST_ROOT/claude/settings.json" 1
  return 0
}

context_directive() {
  awk '/^!`/{sub(/^!`/,""); sub(/`$/,""); print; exit}' "$REPO_ROOT/commands/team.md"
}

@test "agent teams status reports disabled without changing settings" {
  run env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS CLAUDE_CONFIG_DIR="$TEST_ROOT/claude" \
    bash "$SCRIPT" agent-teams-status --settings "$SETTINGS"

  [ "$status" -eq 0 ]
  jq -e '.enabled == false and .source == "none"' <<< "$output" >/dev/null
  [ "$(jq -c . "$SETTINGS")" = "{}" ]
}

@test "agent teams check resolves the enablement layers to the right verdict" {
  local label expected
  while IFS='|' read -r label expected; do
    [ -n "$label" ] || continue
    seed_check_case "$label" || { echo "case=$label unknown" >&2; return 1; }
    run env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS CLAUDE_CONFIG_DIR="$TEST_ROOT/claude" \
      bash "$SCRIPT" agent-teams-check "${CHECK_ARGS[@]}"
    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [ "$output" = "$expected" ] \
      || { echo "case=$label expected=$expected actual=$output" >&2; return 1; }
  done <<CASES
omitted-flag|$DISABLED_MESSAGE
user-settings|$ENABLED_MESSAGE
project-settings|$ENABLED_MESSAGE
explicit-pin-beats-project|$DISABLED_MESSAGE
project-disable-beats-user|$DISABLED_MESSAGE
corrupt-sibling-skipped|$ENABLED_MESSAGE
CASES
}

@test "agent teams check fails closed on a pinned corrupt settings file" {
  printf '%s\n' 'not-json' > "$SETTINGS"

  run env -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
    bash "$SCRIPT" agent-teams-check --settings "$SETTINGS"

  [ "$status" -ne 0 ]
  [[ "$output" == *"settings file is not valid JSON"* ]]
}

@test "agent teams enable requires explicit approval" {
  run bash "$SCRIPT" agent-teams-enable --settings "$SETTINGS"

  [ "$status" -ne 0 ]
  [[ "$output" == *"explicit approval"* ]]
  jq -e 'has("env") | not' "$SETTINGS" >/dev/null
}

@test "approved agent teams enable writes settings and restart guidance is observable" {
  run bash "$SCRIPT" agent-teams-enable --settings "$SETTINGS" --approved

  [ "$status" -eq 0 ]
  jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS == "1"' \
    "$SETTINGS" >/dev/null
  [[ "$output" == *"restart Claude Code"* ]]
}

@test "team context directive resolves roots and the team check without side effects" {
  local label expected_marker absent_marker directive
  directive=$(context_directive)
  [ -n "$directive" ]
  [[ "$directive" != *'${LINK}'* ]]
  while IFS='|' read -r label expected_marker absent_marker; do
    [ -n "$label" ] || continue
    seed_directive_case "$label"
    run env -u LINK -u PROJECT_ROOT -u AGENT_TEAMS_CHECK -u CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS \
      CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      CLAUDE_CONFIG_DIR="$TEST_ROOT/claude" \
      LBWC_SETTINGS_PATH="$SETTINGS" \
      bash -c "cd \"$PROJECT\" && $directive"
    [ "$status" -eq 0 ] || { echo "case=$label status=$status output=$output" >&2; return 1; }
    [[ "$output" == *"Plugin root: "* ]] || { echo "case=$label output=$output" >&2; return 1; }
    [[ "$output" == *"Project root: "* ]] || { echo "case=$label output=$output" >&2; return 1; }
    [[ "$output" == *"$expected_marker"* ]] || { echo "case=$label output=$output" >&2; return 1; }
    [[ "$output" != *"$absent_marker"* ]] || { echo "case=$label output=$output" >&2; return 1; }
    [ ! -e "$PROJECT/.temporary-agent-runfiles" ] || { echo "case=$label created runfiles" >&2; return 1; }
    [ ! -e "$PROJECT/.lbwc-planning" ] || { echo "case=$label created planning" >&2; return 1; }
    [ "$(jq -c . "$SETTINGS")" = "{}" ] || { echo "case=$label changed settings" >&2; return 1; }
  done <<CASES
disabled|$DISABLED_MESSAGE|$ENABLED_MESSAGE
enabled|$ENABLED_MESSAGE|$DISABLED_MESSAGE
CASES
}
