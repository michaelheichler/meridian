write_integration_binary() {
  cat > "$TEST_TEMP_DIR/bin/rtk" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'rtk fixture\n' ;;
  init)
    [ "$#" -eq 3 ] && [ "$2" = -g ] && [ "$3" = --auto-patch ] || exit 91
    mkdir -p "$HOME/.claude/hooks" "$XDG_CONFIG_HOME/rtk"
    printf '#!/bin/bash\nprintf "%%s\\n" rewritten\n' > "$HOME/.claude/hooks/rtk-rewrite.sh"
    printf 'fixture instructions\n' > "$HOME/.claude/RTK.md"
    printf 'fixture config\n' > "$XDG_CONFIG_HOME/rtk/config.toml"
    ;;
  proxy)
    [ "${RTK_FIXTURE_PROXY_FAILURE:-false}" = false ] || exit 81
    shift
    "$@"
    ;;
  *) exit 92 ;;
esac
EOF
  chmod +x "$TEST_TEMP_DIR/bin/rtk"
}

integration_doctor_absent() {
  unset CLAUDE_CONFIG_DIR
  run manager doctor-json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.artifacts_present == false and .rtk_present == false and .doctor_status == "SKIP" and .proof_source == null'
}

integration_doctor_artifacts() {
  unset CLAUDE_CONFIG_DIR
  mkdir -p "$HOME/.config/claude-code/rtk"
  run manager doctor-json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.artifacts_present == true and .doctor_status == "WARN" and .compatibility == "unverified"'
}

integration_doctor_malformed() {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf 'not json\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run manager doctor-json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.doctor_status == "WARN" and .proof_source == null'
}

integration_doctor_project_binary() {
  mkdir -p "$LBWC_RTK_DIR"
  cp "$TEST_TEMP_DIR/release/payload/rtk" "$LBWC_RTK_BINARY"
  run manager doctor-json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.rtk_present == true and .artifacts_present == true and .compatibility == "unverified"'
}

integration_init_dry_run() {
  run manager init --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_CONFIG_DIR" ]
  [ ! -e "$LBWC_RTK_DIR" ]
}

integration_init_publish() {
  write_integration_binary
  manager init --yes
  run manager doctor-json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.rtk_present == true and .compatibility == "hook_active_unverified" and .proof_source == null'
  cmp "$CLAUDE_CONFIG_DIR/RTK.md" <(printf 'fixture instructions\n')
  cmp "$CLAUDE_CONFIG_DIR/rtk/config.toml" <(printf 'fixture config\n')
  run bash "$CLAUDE_CONFIG_DIR/hooks/rtk-rewrite.sh"
  [ "$status" -eq 0 ]
  [ "$output" = rewritten ]
}

integration_init_preserve() {
  write_integration_binary
  mkdir -p "$CLAUDE_CONFIG_DIR/rtk"
  printf 'user config\n' > "$CLAUDE_CONFIG_DIR/rtk/config.toml"
  printf '{"theme":"user choice","hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"user-hook"}]}]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  manager init --yes
  run manager init --yes
  [ "$status" -eq 0 ]
  jq -e '.theme == "user choice" and (.hooks.PreToolUse | length) == 2 and .hooks.PreToolUse[0].hooks[0].command == "user-hook"' "$CLAUDE_CONFIG_DIR/settings.json"
  cmp "$CLAUDE_CONFIG_DIR/rtk/config.toml" <(printf 'user config\n')
}

integration_init_malformed() {
  write_integration_binary
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"hooks":[]}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  cp "$CLAUDE_CONFIG_DIR/settings.json" "$TEST_TEMP_DIR/before"
  run manager init --yes
  [ "$status" -eq 2 ]
  cmp "$CLAUDE_CONFIG_DIR/settings.json" "$TEST_TEMP_DIR/before"
  [ ! -e "$CLAUDE_CONFIG_DIR/hooks" ]
}

integration_init_symlink() {
  write_integration_binary
  mkdir -p "$TEST_TEMP_DIR/outside"
  ln -s "$TEST_TEMP_DIR/outside" "$CLAUDE_CONFIG_DIR"
  run manager init --yes
  [ "$status" -eq 2 ]
  [ ! -e "$TEST_TEMP_DIR/outside/hooks" ]
}

integration_smoke_json() {
  write_integration_binary
  run manager smoke --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.local_smoke == "pass" and .compatibility == "unverified" and .proof_source == null'
}

integration_smoke_text() {
  write_integration_binary
  run manager smoke
  [ "$status" -eq 0 ]
  [[ "$output" == *'compatibility=unverified'* ]]
}

integration_smoke_failure() {
  write_integration_binary
  export RTK_FIXTURE_PROXY_FAILURE=true
  run manager smoke --json
  [ "$status" -eq 2 ]
}

integration_finish_requires_start() {
  run manager smoke-finish
  [ "$status" -eq 2 ]
}

integration_finish_without_transcript() {
  export CLAUDE_SESSION_ID='invalid/session'
  manager smoke-start
  run manager smoke-finish
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.observed_commands == [] and .compatibility == "unverified" and .proof_source == null'
  jq -e '.transcript == "" and .start_line == 0 and (.nonce | length > 0)' "$LBWC_RTK_DIR/rtk-smoke.json"
}

integration_finish_tracks_new_requests() {
  local project transcript
  project=$(pwd -P | tr '/.' '--')
  export CLAUDE_SESSION_ID=fixture-session
  transcript="$CLAUDE_CONFIG_DIR/projects/$project/$CLAUDE_SESSION_ID.jsonl"
  mkdir -p "$(dirname "$transcript")"
  printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git log -n 2 --oneline"}}]}}\n' > "$transcript"
  manager smoke-start
  printf '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la ."}},{"type":"tool_use","name":"Read","input":{"command":"git status --short"}},{"type":"tool_use","name":"Bash","input":{"command":"unrelated"}}]}}\n' >> "$transcript"
  run manager smoke-finish
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.observed_commands == ["ls -la ."] and .compatibility == "unverified" and .proof_source == null'
}

integration_finish_invalid_marker() {
  mkdir -p "$LBWC_RTK_DIR"
  printf '{"nonce":3}\n' > "$LBWC_RTK_DIR/rtk-smoke.json"
  run manager smoke-finish
  [ "$status" -eq 2 ]
}

integration_finish_outside_projects() {
  mkdir -p "$LBWC_RTK_DIR"
  printf '{}\n' > "$TEST_TEMP_DIR/outside.jsonl"
  jq -n --arg transcript "$TEST_TEMP_DIR/outside.jsonl" '{nonce:"fixture",transcript:$transcript,start_line:0}' > "$LBWC_RTK_DIR/rtk-smoke.json"
  run manager smoke-finish
  [ "$status" -eq 2 ]
}
