isolation_spawn_config() {
  jq --argjson value "$1" 'if $value == "missing" then del(.worktree_isolation) else .worktree_isolation=$value end' "$TEST_TEMP_DIR/.meridian/config.json" > "$TEST_TEMP_DIR/config.tmp"
  mv "$TEST_TEMP_DIR/config.tmp" "$TEST_TEMP_DIR/.meridian/config.json"
}

isolation_raw_case() {
  local value="$1" tool="$2" key="$3" identity="$4" isolation="$5" want="$6" json
  isolation_spawn_config "$value"
  json=$(jq -cn --arg tool "$tool" --arg key "$key" --arg name "$identity" --argjson isolation "$isolation" '
    {tool_name:$tool,tool_input:({} | if $key == "none" then . else .[$key]=$name end | if $isolation == null then . else .isolation=$isolation end)}')
  run run_raw_spawn "$json"
  expect_status "$identity" "$want"
  if [ "$want" = 2 ]; then
    expect_output_has "$identity" worktree_isolation
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
  else
    expect_output_empty "$identity"
  fi
}

isolation_missing() { isolation_raw_case '"missing"' Agent subagent_type general-purpose null 0; }
isolation_config_null() { isolation_raw_case null Agent subagent_type scout null 2; }
isolation_config_false() { isolation_raw_case false Agent subagent_type scout null 2; }
isolation_config_true() { isolation_raw_case true Agent subagent_type scout null 2; }
isolation_config_number() { isolation_raw_case 1 Agent subagent_type scout null 2; }
isolation_config_array() { isolation_raw_case '[]' Agent subagent_type scout null 2; }
isolation_config_object() { isolation_raw_case '{}' Agent subagent_type scout null 2; }
isolation_off() { isolation_raw_case '"off"' Agent subagent_type general-purpose null 0; }
isolation_writer() { isolation_raw_case '"on"' Agent subagent_type web-engineer null 2; }
isolation_unknown() { isolation_raw_case '"on"' Agent subagent_type mystery-role null 2; }
isolation_critic_suffix() { isolation_raw_case '"on"' Agent subagent_type mystery-critic null 2; }
isolation_mixed_case() { isolation_raw_case '"on"' Agent subagent_type Scout null 2; }
isolation_agent_type() { isolation_raw_case '"on"' Agent agent_type web-engineer null 2; }
isolation_name() { isolation_raw_case '"on"' Agent name web-engineer null 2; }
isolation_empty_agent() { isolation_raw_case '"on"' Agent none '' null 2; }
isolation_task_identity() { isolation_raw_case '"on"' TaskCreate name web-engineer null 2; }
isolation_task_no_identity() { isolation_raw_case '"on"' TaskCreate none '' null 0; }
isolation_none() { isolation_raw_case '"on"' Agent subagent_type web-engineer '"none"' 2; }
isolation_boolean() { isolation_raw_case '"on"' Agent subagent_type web-engineer true 2; }
isolation_array() { isolation_raw_case '"on"' Agent subagent_type web-engineer '[]' 2; }
isolation_invalid() { isolation_raw_case '"invalid"' Agent subagent_type scout null 2; }
isolation_scout() { isolation_raw_case '"on"' Agent subagent_type scout null 0; }
isolation_lead() { isolation_raw_case '"on"' Agent subagent_type lead null 0; }
isolation_critic() { isolation_raw_case '"on"' Agent subagent_type web-code-critic null 0; }
isolation_explore() { isolation_raw_case '"on"' Agent subagent_type Explore null 0; }

isolation_registered_rejected() {
  build_native_agent isolated-denied default none
  isolation_spawn_config '"on"'
  run run_spawn "$AGENT_NAME"
  expect_status registered 2
  expect_output_has registered worktree_isolation
  [ "$(agent_state)" = registered ]
}

isolation_registered_allowed() {
  build_native_agent isolated-allowed alias alias-model
  isolation_spawn_config '"on"'
  run run_spawn "$AGENT_NAME" '{"isolation":"worktree","cwd":"/wrong/a","working_dir":"/wrong/b","workingDirectory":"/wrong/c","workdir":"/wrong/d"}'
  expect_status registered 0
  printf '%s' "$output" | jq -e '.hookSpecificOutput.updatedInput | .isolation == "worktree" and ([has("cwd"),has("working_dir"),has("workingDirectory"),has("workdir")] | any | not)'
  [ "$(agent_state)" = running ]
}

isolation_frozen() {
  rm "$TEST_TEMP_DIR/.meridian/config.json"
  bash "$SCRIPTS_DIR/meridian-config.sh" init "$TEST_TEMP_DIR/.meridian" >/dev/null
  printf '%s\n' '{"status":"running"}' > "$TEST_TEMP_DIR/.meridian/.execution-state.json"
  run bash "$SCRIPTS_DIR/meridian-config.sh" set "$TEST_TEMP_DIR/.meridian" worktree_isolation '"on"'
  expect_status frozen 1
  expect_output_has frozen 'frozen'
  jq -e '.worktree_isolation != "on"' "$TEST_TEMP_DIR/.meridian/config.json"
}
